#!/usr/bin/env python3
"""Run a real quantized 3x3 layer fragment on WIN3 using an on-board ARM baremetal loop."""

from __future__ import annotations

import argparse
import os
import re
import shutil
import subprocess
import tempfile
import zlib
from dataclasses import dataclass
from pathlib import Path

import numpy as np

from run_win3_real_layer_fragment import (
    DEFAULT_IMAGE,
    DEFAULT_MODEL,
    REPO_ROOT,
    build_run_payload,
    load_interpreter,
    load_quantized_input,
    parse_output_channels,
    requantize_to_int8,
    sign32,
    to_windows_unc,
)

MAILBOX_MAGIC = 0x57494E33  # "WIN3"
MAILBOX_PASS = 0x50415353   # "PASS"
MAILBOX_FAIL = 0x4641494C   # "FAIL"
MAILBOX_HEADER_WORDS = 16
SUMMARY_WORDS_PER_CHANNEL = 4
MAILBOX_RE = re.compile(r"MAILBOX\[(?P<idx>\d+)\]=0x(?P<value>[0-9A-Fa-f]{8})")
CFG9_BIT_FILE = "E:/coralnpu_vivado/zynqmini_7z010/coralnpu_lite_cfg9_ps_csr_build/coralnpu_lite_cfg9_ps_csr.bit"
CFG9_XSA_FILE = "E:/coralnpu_vivado/zynqmini_7z010/coralnpu_lite_cfg9_ps_csr_build/coralnpu_lite_cfg9_ps_csr.xsa"
CFG9_PS7_INIT_FILE = (
    "E:/coralnpu_vivado/zynqmini_7z010/coralnpu_lite_cfg9_ps_csr_build/"
    "coralnpu_lite_cfg9_ps_csr_build.gen/sources_1/bd/design_1/ip/"
    "design_1_processing_system7_0_0/ps7_init.tcl"
)
XSDB_BAT = r"E:\Xilinx\Vivado\2023.2\bin\xsdb.bat"
XSCT_BAT = r"E:\Xilinx\Vitis\2023.2\bin\xsct.bat"
WINDOWS_STAGE_ROOT = Path("/mnt/e/coralnpu_vivado/vendor_examples/project_arm_runtime")


@dataclass(frozen=True)
class MemoryProfile:
    name: str
    load_addr: int
    mailbox_base: int
    stack_addr: int
    program_loader: str
    debug_driver: str
    xsa_file: str = ""


MEMORY_PROFILES: dict[str, MemoryProfile] = {
    "ocm": MemoryProfile(
        name="ocm",
        load_addr=0x00010000,
        mailbox_base=0x00018000,
        stack_addr=0x0001F000,
        program_loader="bin",
        debug_driver="xsdb",
    ),
    "ddr": MemoryProfile(
        name="ddr",
        load_addr=0x00100000,
        mailbox_base=0x00200000,
        stack_addr=0x002FF000,
        program_loader="bin",
        debug_driver="xsdb",
        xsa_file=CFG9_XSA_FILE,
    ),
}


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Run a real quantized 3x3 layer fragment on WIN3 via ARM baremetal.")
    parser.add_argument("--model", type=Path, default=DEFAULT_MODEL, help="INT8 TFLite model path.")
    parser.add_argument("--image", type=Path, default=DEFAULT_IMAGE, help="Input RGB image path.")
    parser.add_argument(
        "--layer",
        choices=["conv2_3x3_a", "conv2_3x3_b", "conv3_3x3_a", "conv3_3x3_b"],
        default="conv2_3x3_b",
        help="Target 3x3 layer name.",
    )
    parser.add_argument("--output_channel", type=int, default=0, help="Output channel index to replay.")
    parser.add_argument(
        "--output_channels",
        type=str,
        default="",
        help="Comma-separated output channel list. If set, it overrides --output_channel.",
    )
    parser.add_argument("--output_row", type=int, default=0, help="Output row index.")
    parser.add_argument(
        "--full_row",
        action="store_true",
        help="Replay the whole output row for these output channels.",
    )
    parser.add_argument(
        "--memory-profile",
        choices=sorted(MEMORY_PROFILES),
        default="ocm",
        help="Execution memory profile: ocm keeps the current 32KB fast path, ddr uses a formal DDR-resident ARM image.",
    )
    parser.add_argument(
        "--readback-mode",
        choices=["full", "summary"],
        default="full",
        help="full reads back every int32 result; summary reads back per-channel hash/sum/min/max for faster large-run validation.",
    )
    parser.add_argument(
        "--xsdb-retries",
        type=int,
        default=2,
        help="Retry count for transient XSDB/DAP transport failures.",
    )
    return parser.parse_args()


def c_hex32(value: int) -> str:
    return f"0x{value & 0xFFFFFFFF:08X}u"


def c_int32(value: int) -> str:
    return str(int(np.int32(value)))


def asm_hex32(value: int) -> str:
    return f"0x{value & 0xFFFFFFFF:08X}"


def program_max_bytes(profile: MemoryProfile) -> int:
    return profile.mailbox_base - profile.load_addr


def mailbox_max_bytes(profile: MemoryProfile) -> int:
    return profile.stack_addr - profile.mailbox_base


def fnv1a_hash_int32_row(values: list[int]) -> int:
    hash_value = 0x811C9DC5
    for value in values:
        word = int(value) & 0xFFFFFFFF
        for shift in (0, 8, 16, 24):
            hash_value ^= (word >> shift) & 0xFF
            hash_value = (hash_value * 0x01000193) & 0xFFFFFFFF
    return hash_value


def generate_arm_source(payloads: list[dict], profile: MemoryProfile, readback_mode: str) -> str:
    channel_count = len(payloads)
    width = len(payloads[0]["final_row_int32"])
    tile_count = len(payloads[0]["tiles"])
    cases_per_tile = len(payloads[0]["tiles"][0]["cases"])
    total_cases = tile_count * cases_per_tile * channel_count
    readback_full = 1 if readback_mode == "full" else 0

    start_col_lines = ", ".join(f"{tile['start_col']}u" for tile in payloads[0]["tiles"])
    bias_lines = ", ".join(c_int32(payload["adjusted_bias"]) for payload in payloads)
    output_channel_lines = ", ".join(f"{payload['output_channel']}u" for payload in payloads)

    input_tile_lines = []
    for tile in payloads[0]["tiles"]:
        case_lines = []
        for case in tile["cases"]:
            case_lines.append(
                "    {"
                f"{c_hex32(case['row0_lo'])}, {c_hex32(case['row0_hi'])}, "
                f"{c_hex32(case['row1_lo'])}, {c_hex32(case['row1_hi'])}, "
                f"{c_hex32(case['row2_lo'])}, {c_hex32(case['row2_hi'])}"
                "},"
            )
        input_tile_lines.append("  {\n" + "\n".join(case_lines) + "\n  },")

    weight_channel_lines = []
    for payload in payloads:
        weight_lines = []
        first_tile_cases = payload["tiles"][0]["cases"]
        for case in first_tile_cases:
            weight_lines.append(
                "    {"
                f"{c_hex32(case['wgt0'])}, {c_hex32(case['wgt1'])}, {c_hex32(case['wgt2'])}"
                "},"
            )
        weight_channel_lines.append("  {\n" + "\n".join(weight_lines) + "\n  },")

    return f"""#include <stdint.h>

#define PERIPH_BASE_ADDR    0x43C00000u
#define MAILBOX_BASE_ADDR   {c_hex32(profile.mailbox_base)}
#define MAILBOX_MAGIC       {c_hex32(MAILBOX_MAGIC)}
#define MAILBOX_PASS        {c_hex32(MAILBOX_PASS)}
#define MAILBOX_FAIL        {c_hex32(MAILBOX_FAIL)}

#define REG_GESTURE_WGT0    0x110u
#define REG_GESTURE_WGT1    0x114u
#define REG_GESTURE_WGT2    0x118u
#define REG_GESTURE_BIAS    0x11Cu
#define REG_WIN3_CTRL       0x180u
#define REG_WIN3_ROW0_LO    0x184u
#define REG_WIN3_ROW0_HI    0x188u
#define REG_WIN3_ROW1_LO    0x18Cu
#define REG_WIN3_ROW1_HI    0x190u
#define REG_WIN3_ROW2_LO    0x194u
#define REG_WIN3_ROW2_HI    0x198u
#define REG_WIN3_STATUS     0x19Cu
#define REG_WIN3_RESULT0    0x1A0u
#define REG_WIN3_RESULT1    0x1A4u
#define REG_WIN3_RESULT2    0x1A8u

#define WIN3_CTRL_START     0x00000001u
#define WIN3_CTRL_CLEAR     0x00000002u
#define WIN3_STATUS_DONE    0x00000002u
#define WIN3_TIMEOUT_LIMIT  200000u
#define MAILBOX_HEADER_WORDS {MAILBOX_HEADER_WORDS}u
#define CHANNEL_COUNT       {channel_count}u
#define TILE_COUNT          {tile_count}u
#define CASES_PER_TILE      {cases_per_tile}u
#define ROW_WIDTH           {width}u
#define CASE_COUNT          {total_cases}u
#define READBACK_FULL       {readback_full}u

typedef struct {{
  uint32_t row0_lo;
  uint32_t row0_hi;
  uint32_t row1_lo;
  uint32_t row1_hi;
  uint32_t row2_lo;
  uint32_t row2_hi;
}} InputCase;

typedef struct {{
  uint32_t wgt0;
  uint32_t wgt1;
  uint32_t wgt2;
}} WeightCase;

static const uint32_t start_cols[TILE_COUNT] = {{{start_col_lines}}};
static const InputCase input_cases[TILE_COUNT][CASES_PER_TILE] = {{
{chr(10).join(input_tile_lines)}
}};
static const int32_t adjusted_bias[CHANNEL_COUNT] = {{{bias_lines}}};
static const uint32_t output_channel_ids[CHANNEL_COUNT] = {{{output_channel_lines}}};
static const WeightCase channel_weights[CHANNEL_COUNT][CASES_PER_TILE] = {{
{chr(10).join(weight_channel_lines)}
}};

static int32_t accum_row[CHANNEL_COUNT][ROW_WIDTH];
static int32_t final_row[CHANNEL_COUNT][ROW_WIDTH];

static volatile uint32_t mailbox_region[MAILBOX_HEADER_WORDS + CHANNEL_COUNT * (READBACK_FULL ? ROW_WIDTH : {SUMMARY_WORDS_PER_CHANNEL}u)];

static inline void dsb_sy(void) {{
  __asm__ volatile("dsb sy" ::: "memory");
}}

static void delay_cycles(unsigned count) {{
  while (count-- != 0u) {{
    __asm__ volatile("nop");
  }}
}}

static void write32(uint32_t offset, uint32_t value) {{
  volatile uint32_t *addr = (volatile uint32_t *)(PERIPH_BASE_ADDR + offset);
  *addr = value;
  dsb_sy();
}}

static uint32_t read32(uint32_t offset) {{
  volatile uint32_t *addr = (volatile uint32_t *)(PERIPH_BASE_ADDR + offset);
  uint32_t value = *addr;
  dsb_sy();
  return value;
}}

static void mailbox_write(unsigned index, uint32_t value) {{
  mailbox_region[index] = value;
  dsb_sy();
}}

static void clear_mailbox(unsigned words) {{
  for (unsigned i = 0u; i < words; ++i) {{
    mailbox_write(i, 0u);
  }}
}}

static uint32_t fnv1a_hash_row(const int32_t *row) {{
  uint32_t hash = 0x811C9DC5u;
  for (unsigned col = 0u; col < ROW_WIDTH; ++col) {{
    const uint32_t word = (uint32_t)row[col];
    hash ^= (word >> 0) & 0xFFu;
    hash *= 0x01000193u;
    hash ^= (word >> 8) & 0xFFu;
    hash *= 0x01000193u;
    hash ^= (word >> 16) & 0xFFu;
    hash *= 0x01000193u;
    hash ^= (word >> 24) & 0xFFu;
    hash *= 0x01000193u;
  }}
  return hash;
}}

void arm_win3_main(void) {{
  const unsigned mailbox_words =
      MAILBOX_HEADER_WORDS + CHANNEL_COUNT * (READBACK_FULL ? ROW_WIDTH : {SUMMARY_WORDS_PER_CHANNEL}u);
  clear_mailbox(mailbox_words);
  for (unsigned ch = 0u; ch < CHANNEL_COUNT; ++ch) {{
    for (unsigned col = 0u; col < ROW_WIDTH; ++col) {{
      accum_row[ch][col] = 0;
      final_row[ch][col] = 0;
    }}
  }}

  uint32_t fail_stage = 0u;
  uint32_t fail_case = 0u;
  uint32_t last_status = 0u;

  for (unsigned ch = 0u; ch < CHANNEL_COUNT; ++ch) {{
    for (unsigned tile_idx = 0u; tile_idx < TILE_COUNT; ++tile_idx) {{
      const uint32_t start_col = start_cols[tile_idx];
      for (unsigned ic = 0u; ic < CASES_PER_TILE; ++ic) {{
        const InputCase *input = &input_cases[tile_idx][ic];
        const WeightCase *weight = &channel_weights[ch][ic];

        write32(REG_WIN3_CTRL, WIN3_CTRL_CLEAR);
        delay_cycles(128u);
        write32(REG_GESTURE_WGT0, weight->wgt0);
        write32(REG_GESTURE_WGT1, weight->wgt1);
        write32(REG_GESTURE_WGT2, weight->wgt2);
        write32(REG_GESTURE_BIAS, 0u);
        write32(REG_WIN3_ROW0_LO, input->row0_lo);
        write32(REG_WIN3_ROW0_HI, input->row0_hi);
        write32(REG_WIN3_ROW1_LO, input->row1_lo);
        write32(REG_WIN3_ROW1_HI, input->row1_hi);
        write32(REG_WIN3_ROW2_LO, input->row2_lo);
        write32(REG_WIN3_ROW2_HI, input->row2_hi);
        write32(REG_WIN3_CTRL, WIN3_CTRL_START);

        uint32_t timeout = 0u;
        while (((read32(REG_WIN3_STATUS) & WIN3_STATUS_DONE) == 0u) && (timeout < WIN3_TIMEOUT_LIMIT)) {{
          timeout++;
        }}
        if (timeout == WIN3_TIMEOUT_LIMIT) {{
          fail_stage = 1u;
          fail_case = ch * (TILE_COUNT * CASES_PER_TILE) + tile_idx * CASES_PER_TILE + ic;
          break;
        }}

        const int32_t result0 = (int32_t)read32(REG_WIN3_RESULT0);
        const int32_t result1 = (int32_t)read32(REG_WIN3_RESULT1);
        const int32_t result2 = (int32_t)read32(REG_WIN3_RESULT2);
        last_status = read32(REG_WIN3_STATUS);

        accum_row[ch][start_col + 0u] += result0;
        accum_row[ch][start_col + 1u] += result1;
        accum_row[ch][start_col + 2u] += result2;
      }}
      if (fail_stage != 0u) {{
        break;
      }}
    }}
    if (fail_stage != 0u) {{
      break;
    }}
  }}

  for (unsigned ch = 0u; ch < CHANNEL_COUNT; ++ch) {{
    for (unsigned col = 0u; col < ROW_WIDTH; ++col) {{
      final_row[ch][col] = accum_row[ch][col] + adjusted_bias[ch];
    }}
  }}

  mailbox_write(0u, MAILBOX_MAGIC);
  mailbox_write(1u, (fail_stage == 0u) ? MAILBOX_PASS : MAILBOX_FAIL);
  mailbox_write(2u, fail_stage);
  mailbox_write(3u, fail_case);
  mailbox_write(4u, 0u);
  mailbox_write(5u, 0u);
  mailbox_write(6u, 0u);
  mailbox_write(7u, 0u);
  mailbox_write(8u, 0u);
  mailbox_write(9u, 0u);
  mailbox_write(10u, CASE_COUNT);
  mailbox_write(11u, CHANNEL_COUNT);
  mailbox_write(12u, ROW_WIDTH);
  mailbox_write(13u, output_channel_ids[0]);
  mailbox_write(14u, output_channel_ids[CHANNEL_COUNT - 1u]);
  mailbox_write(15u, last_status);

  unsigned mailbox_index = MAILBOX_HEADER_WORDS;
  for (unsigned ch = 0u; ch < CHANNEL_COUNT; ++ch) {{
    if (READBACK_FULL) {{
      for (unsigned col = 0u; col < ROW_WIDTH; ++col) {{
        mailbox_write(mailbox_index++, (uint32_t)final_row[ch][col]);
      }}
    }} else {{
      int32_t row_sum = 0;
      int32_t row_min = final_row[ch][0];
      int32_t row_max = final_row[ch][0];
      for (unsigned col = 0u; col < ROW_WIDTH; ++col) {{
        const int32_t value = final_row[ch][col];
        row_sum += value;
        if (value < row_min) {{
          row_min = value;
        }}
        if (value > row_max) {{
          row_max = value;
        }}
      }}
      mailbox_write(mailbox_index++, fnv1a_hash_row(final_row[ch]));
      mailbox_write(mailbox_index++, (uint32_t)row_sum);
      mailbox_write(mailbox_index++, (uint32_t)row_min);
      mailbox_write(mailbox_index++, (uint32_t)row_max);
    }}
  }}
}}

__attribute__((naked, noreturn, section(".text.start")))
void _start(void) {{
  __asm__ volatile(
      "mrc p15, 0, r0, c1, c0, 0\\n"
      "bic r0, r0, #1\\n"
      "bic r0, r0, #4\\n"
      "bic r0, r0, #2048\\n"
      "mov r1, #0x1000\\n"
      "bic r0, r0, r1\\n"
      "mcr p15, 0, r0, c1, c0, 0\\n"
      "dsb sy\\n"
      "isb\\n"
      "ldr sp, ={asm_hex32(profile.stack_addr)}\\n"
      "bl arm_win3_main\\n"
      "1:\\n"
      "wfe\\n"
      "b 1b\\n");
}}
"""


def write_linker_script(lds_path: Path, profile: MemoryProfile) -> None:
    lds_path.write_text(
        f"""ENTRY(_start)

SECTIONS
{{
  . = 0x{profile.load_addr:08X};

  .text : ALIGN(4)
  {{
    *(.text.start)
    *(.text*)
    *(.rodata*)
  }}

  .data : ALIGN(4)
  {{
    *(.data*)
  }}

  .bss : ALIGN(4)
  {{
    *(.bss*)
    *(COMMON)
  }}

  /DISCARD/ :
  {{
    *(.ARM.exidx*)
    *(.ARM.extab*)
    *(.comment)
    *(.note*)
  }}
}}
""",
        encoding="utf-8",
    )


def compile_arm_binary(src_path: Path, elf_path: Path, bin_path: Path, lds_path: Path, profile: MemoryProfile) -> int:
    clang_bin = os.environ.get("CLANG", "clang")
    ld_lld = Path(os.environ.get("LD_LLD", str(REPO_ROOT / "local_env" / "toolchains" / "lld-14" / "usr" / "bin" / "ld.lld-14")))
    objcopy_bin = os.environ.get("LLVM_OBJCOPY", "llvm-objcopy-14")
    if not ld_lld.exists():
        raise FileNotFoundError(f"Missing ld.lld for ARM baremetal linking: {ld_lld}")

    obj_path = src_path.with_suffix(".o")
    subprocess.run(
        [
            clang_bin,
            "-target",
            "armv7-none-eabi",
            "-mcpu=cortex-a9",
            "-marm",
            "-Oz",
            "-ffreestanding",
            "-fno-builtin",
            "-nostdlib",
            "-fno-stack-protector",
            "-fno-unwind-tables",
            "-fno-asynchronous-unwind-tables",
            "-fdata-sections",
            "-ffunction-sections",
            "-c",
            str(src_path),
            "-o",
            str(obj_path),
        ],
        check=True,
        cwd=REPO_ROOT,
    )
    subprocess.run(
        [
            str(ld_lld),
            "-T",
            str(lds_path),
            "--gc-sections",
            "-o",
            str(elf_path),
            str(obj_path),
        ],
        check=True,
        cwd=REPO_ROOT,
    )
    subprocess.run(
        [
            objcopy_bin,
            "-O",
            "binary",
            str(elf_path),
            str(bin_path),
        ],
        check=True,
        cwd=REPO_ROOT,
    )
    program_footprint = measure_elf_footprint(elf_path)
    if program_footprint > program_max_bytes(profile):
        raise RuntimeError(
            f"ARM program too large for {profile.name.upper()} execution window: "
            f"{program_footprint} bytes > {program_max_bytes(profile)} bytes"
        )
    return program_footprint


def measure_elf_footprint(elf_path: Path) -> int:
    size_bin = os.environ.get("LLVM_SIZE", "llvm-size-14")
    result = subprocess.run(
        [size_bin, "-A", "-d", str(elf_path)],
        check=True,
        capture_output=True,
        text=True,
        cwd=REPO_ROOT,
    )
    footprint = 0
    for line in result.stdout.splitlines():
        parts = line.split()
        if len(parts) != 3:
            continue
        section_name, size_str, _addr_str = parts
        if section_name.startswith(".") and section_name not in {".ARM.attributes"}:
            footprint += int(size_str)
    if footprint <= 0:
        raise RuntimeError(f"Unable to measure ELF footprint for {elf_path}.\n{result.stdout}")
    return footprint


def lookup_symbol_addr(elf_path: Path, symbol: str) -> int:
    nm_bin = os.environ.get("LLVM_NM", "llvm-nm-14")
    result = subprocess.run(
        [nm_bin, "-n", str(elf_path)],
        check=True,
        capture_output=True,
        text=True,
        cwd=REPO_ROOT,
    )
    for line in result.stdout.splitlines():
        parts = line.strip().split()
        if len(parts) >= 3 and parts[2] == symbol:
            return int(parts[0], 16)
    raise RuntimeError(f"Unable to find symbol {symbol!r} in ELF {elf_path}")


def write_debug_tcl(
    elf_windows_path: str,
    bin_windows_path: str,
    mailbox_words: int,
    mailbox_addr: int,
    profile: MemoryProfile,
    tcl_path: Path,
    progress_windows_path: str,
) -> None:
    mailbox_poll_lines = [
        'targets -set -filter {name =~ "APU"}',
        "configparams force-mem-accesses 1",
        "set mailbox_wait_ms 0",
        "set mailbox_magic 0",
        "while {$mailbox_wait_ms < 180000} {",
        "  set mailbox_magic [read32_int $mailbox_addr]",
        "  if {$mailbox_magic != 0} { break }",
        "  after 100",
        "  incr mailbox_wait_ms 100",
        "}",
        'puts [format "WIN3_ARM_MAILBOX_WAIT_MS %d" $mailbox_wait_ms]',
        'puts [format "WIN3_ARM_MAILBOX_MAGIC0 0x%08X" $mailbox_magic]',
        'targets -set -filter {name =~ "ARM Cortex-A9 MPCore #0"}',
        "catch {stop}",
        'targets -set -filter {name =~ "APU"}',
        "configparams force-mem-accesses 1",
    ]
    if profile.name == "ddr":
        lines = [
            f"set bit_file {CFG9_BIT_FILE}",
            f"set xsa_file {profile.xsa_file}",
            f"set ps7_init_file {CFG9_PS7_INIT_FILE}",
            f"set bin_file {bin_windows_path}",
            f"set progress_file {progress_windows_path}",
            f"set load_addr 0x{profile.load_addr:08X}",
            f"set mailbox_addr 0x{mailbox_addr:08X}",
            f"set mailbox_words {mailbox_words}",
            "proc read32_int {addr} { return [mrd -force -value $addr] }",
            "proc clear_mailbox_host {} {",
            "  targets -set -filter {name =~ \"APU\"}",
            "  configparams force-mem-accesses 1",
            "  for {set i 0} {$i < $::mailbox_words} {incr i} {",
            "    mwr -force [expr {$::mailbox_addr + 4 * $i}] 0",
            "  }",
            "}",
            "proc logmsg {msg} {",
            "  set fp [open $::progress_file a]",
            "  puts $fp $msg",
            "  close $fp",
            "}",
            "proc ensure_a9 {} {",
            '  set rc [catch {targets -set -filter {name =~ "ARM Cortex-A9 MPCore #0"}} msg]',
            "  if {$rc == 0} { return }",
            '  puts "ENSURE_A9_RETRY $msg"',
            '  set drc [catch {targets -set -filter {name =~ "DAP*"}} dmsg]',
            "  if {$drc == 0} {",
            '    catch {rst -system}',
            "    after 1500",
            "  }",
            '  targets -set -filter {name =~ "ARM Cortex-A9 MPCore #0"}',
            "}",
            "catch {file delete -force $progress_file}",
            'logmsg "STEP connect"',
            "connect",
            "after 1000",
            'logmsg "STEP ensure_a9_pre"',
            "ensure_a9",
            "set rst_rc [catch {rst -system} rst_msg]",
            'puts [format "WIN3_ARM_RST_SYSTEM_RC %d" $rst_rc]',
            'puts [format "WIN3_ARM_RST_SYSTEM_MSG %s" $rst_msg]',
            "after 1500",
            'logmsg "STEP ensure_a9_post_reset"',
            "ensure_a9",
            'logmsg "STEP fpga"',
            "fpga -file $bit_file",
            "after 1500",
            "set dap_after_fpga_rc [catch {targets -set -filter {name =~ \"DAP*\"}} dap_after_fpga_msg]",
            "if {$dap_after_fpga_rc == 0} {",
            "  catch {rst -system}",
            "  after 1500",
            "}",
            'logmsg "STEP ensure_a9_post_fpga"',
            "ensure_a9",
            "catch {stop}",
            'targets -set -filter {name =~ "ARM Cortex-A9 MPCore #0"}',
            "catch {stop}",
            "catch {rst -processor}",
            "after 200",
            "catch {stop}",
            'targets -set -filter {name =~ "APU"}',
            "configparams force-mem-accesses 1",
            'logmsg "STEP dow_bin_ddr"',
            "set dow_rc [catch {dow -data -bypass-cache-sync $bin_file $load_addr} dow_msg]",
            'puts [format "WIN3_ARM_DOW_RC %d" $dow_rc]',
            'puts [format "WIN3_ARM_DOW_MSG %s" $dow_msg]',
            "if {$dow_rc != 0} { exit 1 }",
            'logmsg "STEP clear_mailbox_host"',
            "clear_mailbox_host",
            'targets -set -filter {name =~ "APU"}',
            "configparams force-mem-accesses 1",
            'puts [format "WIN3_ARM_LOAD_WORD0 0x%08X" [read32_int $load_addr]]',
            'targets -set -filter {name =~ "ARM Cortex-A9 MPCore #0"}',
            'logmsg "STEP con_addr"',
            "con -addr $load_addr",
        ]
        lines.extend(mailbox_poll_lines)
        lines.extend(
            [
                'puts "WIN3_ARM_MAILBOX_BEGIN"',
                "for {set i 0} {$i < $mailbox_words} {incr i} {",
                "  set addr [expr {$mailbox_addr + 4 * $i}]",
                "  set value [mrd -force -value $addr]",
                '  puts [format {MAILBOX[%d]=0x%08X} $i $value]',
                "}",
                'puts "WIN3_ARM_MAILBOX_END"',
                "exit",
            ]
        )
    else:
        lines = [
            f"set load_addr 0x{profile.load_addr:08X}",
            f"set mailbox_addr 0x{mailbox_addr:08X}",
            f"set mailbox_words {mailbox_words}",
            f"set bit_file {CFG9_BIT_FILE}",
            f"set elf_file {elf_windows_path}",
            f"set progress_file {progress_windows_path}",
            "proc read32_int {addr} {",
            "  return [mrd -force -value $addr]",
            "}",
            "proc clear_mailbox_host {} {",
            '  targets -set -filter {name =~ "APU"}',
            "  configparams force-mem-accesses 1",
            "  for {set i 0} {$i < $::mailbox_words} {incr i} {",
            "    mwr -force [expr {$::mailbox_addr + 4 * $i}] 0",
            "  }",
            "}",
            "proc logmsg {msg} {",
            "  set fp [open $::progress_file a]",
            "  puts $fp $msg",
            "  close $fp",
            "}",
            "proc stop_a9_all {} {",
            '  foreach core {"ARM Cortex-A9 MPCore #0" "ARM Cortex-A9 MPCore #1"} {',
            '    if {[catch {targets -set -filter "name =~ {$core}"} msg] == 0} {',
            "      catch {stop}",
            "    }",
            "  }",
            "}",
            "catch {file delete -force $progress_file}",
            'logmsg "STEP connect"',
            "connect",
            "after 1000",
            'logmsg "STEP stop_a9_all_pre_fpga"',
            "stop_a9_all",
            'targets -set -filter {name =~ "xc7z010"}',
            'logmsg "STEP fpga"',
            "fpga -file $bit_file",
            "after 1500",
            'logmsg "STEP stop_a9_all_post_fpga"',
            "stop_a9_all",
            'targets -set -filter {name =~ "ARM Cortex-A9 MPCore #0"}',
            "catch {stop}",
            'logmsg "STEP dow_elf_ocm"',
            "set dow_rc [catch {dow $elf_file} dow_msg]",
            'puts [format "WIN3_ARM_DOW_RC %d" $dow_rc]',
            'puts [format "WIN3_ARM_DOW_MSG %s" $dow_msg]',
            "if {$dow_rc != 0} { exit 1 }",
            'logmsg "STEP clear_mailbox_host"',
            "clear_mailbox_host",
            'targets -set -filter {name =~ "ARM Cortex-A9 MPCore #0"}',
            "catch {stop}",
            'logmsg "STEP con_addr_ocm"',
            "con -addr $load_addr",
        ]
        lines.extend(mailbox_poll_lines)
        lines.extend(
            [
                'puts "WIN3_ARM_MAILBOX_BEGIN"',
                "for {set i 0} {$i < $mailbox_words} {incr i} {",
                "  set addr [expr {$mailbox_addr + 4 * $i}]",
                "  set value [mrd -force -value $addr]",
                '  puts [format {MAILBOX[%d]=0x%08X} $i $value]',
                "}",
                'puts "WIN3_ARM_MAILBOX_END"',
                "exit",
            ]
        )
    tcl_path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def run_debug_script(tcl_windows_path: str, profile: MemoryProfile) -> str:
    driver_bat = XSCT_BAT if profile.debug_driver == "xsct" else XSDB_BAT
    cmd = (
        "cd /d E:\\coralnpu_vivado\\zynqmini_7z010 && "
        f"call {driver_bat} "
        f"{tcl_windows_path}"
    )
    result = subprocess.run(
        ["cmd.exe", "/c", cmd],
        check=False,
        capture_output=True,
    )
    stdout = result.stdout
    stderr = result.stderr
    if isinstance(stdout, bytes):
        try:
            stdout_text = stdout.decode("utf-8")
        except UnicodeDecodeError:
            stdout_text = stdout.decode("gbk", errors="ignore")
    else:
        stdout_text = stdout
    if isinstance(stderr, bytes):
        try:
            stderr_text = stderr.decode("utf-8")
        except UnicodeDecodeError:
            stderr_text = stderr.decode("gbk", errors="ignore")
    else:
        stderr_text = stderr
    if result.returncode != 0:
        raise RuntimeError(
            f"{profile.debug_driver.upper()} failed with code {result.returncode}.\n"
            f"STDOUT:\n{stdout_text}\nSTDERR:\n{stderr_text}"
        )
    return stdout_text


def is_retryable_xsdb_error(message: str) -> bool:
    retry_markers = (
        "AP transaction timeout",
        "AP transaction error",
        "DAP status",
        "MMU section translation fault",
        "Cannot reset APU",
        "Cannot halt processor core",
        "Memory write error at 0x43C",
        "Memory read error at 0x43C",
    )
    return any(marker in message for marker in retry_markers)


def to_windows_local_e(path: Path) -> str:
    resolved = path.resolve()
    try:
        relative = resolved.relative_to(Path("/mnt/e"))
    except ValueError as exc:
        raise ValueError(f"Path is not on /mnt/e and cannot be passed as local Windows E: path: {resolved}") from exc
    return "E:/" + relative.as_posix()


def stage_debug_artifacts(
    elf_path: Path,
    bin_path: Path,
    profile: MemoryProfile,
    mailbox_words: int,
    mailbox_addr: int,
) -> tuple[Path, str]:
    WINDOWS_STAGE_ROOT.mkdir(parents=True, exist_ok=True)
    stage_dir = Path(tempfile.mkdtemp(prefix=f"{profile.name}_", dir=WINDOWS_STAGE_ROOT))
    staged_elf = stage_dir / "arm_win3_runner.elf"
    staged_bin = stage_dir / "arm_win3_runner.bin"
    staged_tcl = stage_dir / "run_arm_win3.tcl"
    staged_progress = stage_dir / "run_arm_win3_progress.log"
    shutil.copy2(elf_path, staged_elf)
    shutil.copy2(bin_path, staged_bin)
    write_debug_tcl(
        elf_windows_path=to_windows_local_e(staged_elf),
        bin_windows_path=to_windows_local_e(staged_bin),
        mailbox_words=mailbox_words,
        mailbox_addr=mailbox_addr,
        profile=profile,
        tcl_path=staged_tcl,
        progress_windows_path=to_windows_local_e(staged_progress),
    )
    return staged_progress, to_windows_local_e(staged_tcl)


def parse_mailbox(stdout: str, mailbox_words: int) -> list[int]:
    values = [None] * mailbox_words
    for line in stdout.splitlines():
        match = MAILBOX_RE.search(line)
        if not match:
            continue
        idx = int(match.group("idx"))
        if 0 <= idx < mailbox_words:
            values[idx] = int(match.group("value"), 16)
    if any(value is None for value in values):
        missing = [idx for idx, value in enumerate(values) if value is None][:16]
        raise RuntimeError(f"Missing mailbox words {missing}. Full XSDB output:\n{stdout}")
    return [int(value) for value in values]


def execute_payload_chunk(payloads: list[dict], xsdb_retries: int, profile: MemoryProfile, readback_mode: str) -> dict:
    width = len(payloads[0]["final_row_int32"])
    words_per_channel = width if readback_mode == "full" else SUMMARY_WORDS_PER_CHANNEL
    mailbox_words = MAILBOX_HEADER_WORDS + len(payloads) * words_per_channel
    mailbox_bytes = mailbox_words * 4
    if mailbox_bytes > mailbox_max_bytes(profile):
        raise RuntimeError(
            f"ARM mailbox too large for {profile.name.upper()} window: "
            f"{mailbox_bytes} bytes > {mailbox_max_bytes(profile)} bytes"
        )

    with tempfile.TemporaryDirectory(prefix="win3_real_layer_arm_") as tmp_dir:
        tmp_path = Path(tmp_dir)
        src_path = tmp_path / "arm_win3_runner.c"
        elf_path = tmp_path / "arm_win3_runner.elf"
        bin_path = tmp_path / "arm_win3_runner.bin"
        linker_script = tmp_path / "arm_win3_runner.ld"
        tcl_path = tmp_path / "run_arm_win3.tcl"
        src_path.write_text(generate_arm_source(payloads, profile, readback_mode), encoding="utf-8")
        write_linker_script(linker_script, profile)
        program_size = compile_arm_binary(src_path, elf_path, bin_path, linker_script, profile)
        mailbox_addr = profile.mailbox_base
        if profile.name == "ocm":
            mailbox_addr = lookup_symbol_addr(elf_path, "mailbox_region")
        progress_path, tcl_windows_path = stage_debug_artifacts(
            elf_path=elf_path,
            bin_path=bin_path,
            profile=profile,
            mailbox_words=mailbox_words,
            mailbox_addr=mailbox_addr,
        )
        last_error: RuntimeError | None = None
        for attempt in range(1, max(xsdb_retries, 1) + 1):
            try:
                stdout = run_debug_script(tcl_windows_path, profile)
                break
            except RuntimeError as exc:
                if attempt >= max(xsdb_retries, 1) or not is_retryable_xsdb_error(str(exc)):
                    if progress_path.exists():
                        print(f"ARM_DEBUG_PROGRESS_LOG {progress_path}")
                    raise
                last_error = exc
        else:
            if last_error is not None:
                raise last_error
            raise RuntimeError("XSDB execution exhausted retries without a captured error.")

    mailbox = parse_mailbox(stdout, mailbox_words)
    magic = mailbox[0]
    status = mailbox[1]
    fail_stage = mailbox[2]
    fail_case = mailbox[3]
    if magic != MAILBOX_MAGIC:
        raise RuntimeError(f"Unexpected mailbox magic: 0x{magic:08X}")
    if status != MAILBOX_PASS:
        raise RuntimeError(
            "ARM WIN3 runner failed.\n"
            f"fail_stage={fail_stage}\n"
            f"fail_case={fail_case}\n"
            f"expected0={sign32(mailbox[4])}\n"
            f"actual0={sign32(mailbox[5])}\n"
            f"expected1={sign32(mailbox[6])}\n"
            f"actual1={sign32(mailbox[7])}\n"
            f"expected2={sign32(mailbox[8])}\n"
            f"actual2={sign32(mailbox[9])}\n"
        )

    offset = MAILBOX_HEADER_WORDS
    board_rows_int32: list[list[int]] = []
    board_rows_int8_q: list[list[int]] = []
    board_row_summaries: list[dict] = []
    for payload in payloads:
        if readback_mode == "full":
            board_row_int32 = [sign32(v) for v in mailbox[offset : offset + width]]
            offset += width
            if board_row_int32 != payload["final_row_int32"]:
                raise RuntimeError(
                    "ARM WIN3 final int32 row mismatch software golden.\n"
                    f"output_channel={payload['output_channel']}\n"
                    f"board={board_row_int32}\n"
                    f"software={payload['final_row_int32']}\n"
                )
            board_row_int8_q = [
                requantize_to_int8(
                    raw_value=value,
                    input_scale=payload["activation_scale"],
                    weight_scale=payload["weight_scale"],
                    output_scale=payload["output_scale"],
                    output_zero_point=payload["output_zero_point"],
                )
                for value in board_row_int32
            ]
            if board_row_int8_q != payload["tflite_row_q"]:
                raise RuntimeError(
                    "ARM WIN3 requantized int8 row mismatch TFLite final output row.\n"
                    f"output_channel={payload['output_channel']}\n"
                    f"board={board_row_int8_q}\n"
                    f"tflite={payload['tflite_row_q']}\n"
                )
            board_rows_int32.append(board_row_int32)
            board_rows_int8_q.append(board_row_int8_q)
        else:
            board_summary = {
                "int32_hash": mailbox[offset + 0] & 0xFFFFFFFF,
                "int32_sum": sign32(mailbox[offset + 1]),
                "int32_min": sign32(mailbox[offset + 2]),
                "int32_max": sign32(mailbox[offset + 3]),
            }
            offset += SUMMARY_WORDS_PER_CHANNEL
            expected_row = payload["final_row_int32"]
            expected_summary = {
                "int32_hash": fnv1a_hash_int32_row(expected_row),
                "int32_sum": sum(expected_row),
                "int32_min": min(expected_row),
                "int32_max": max(expected_row),
            }
            if board_summary != expected_summary:
                raise RuntimeError(
                    "ARM WIN3 summary readback mismatch software golden.\n"
                    f"output_channel={payload['output_channel']}\n"
                    f"board={board_summary}\n"
                    f"software={expected_summary}\n"
                )
            board_row_summaries.append(board_summary)

    return {
        "payloads": payloads,
        "program_size": program_size,
        "mailbox": mailbox,
        "board_rows_int32": board_rows_int32,
        "board_rows_int8_q": board_rows_int8_q,
        "board_row_summaries": board_row_summaries,
    }


def estimate_program_size(payloads: list[dict], profile: MemoryProfile, readback_mode: str) -> int:
    width = len(payloads[0]["final_row_int32"])
    words_per_channel = width if readback_mode == "full" else SUMMARY_WORDS_PER_CHANNEL
    mailbox_words = MAILBOX_HEADER_WORDS + len(payloads) * words_per_channel
    mailbox_bytes = mailbox_words * 4
    if mailbox_bytes > mailbox_max_bytes(profile):
        raise RuntimeError(
            f"ARM mailbox too large for {profile.name.upper()} window: "
            f"{mailbox_bytes} bytes > {mailbox_max_bytes(profile)} bytes"
        )

    with tempfile.TemporaryDirectory(prefix="win3_real_layer_arm_estimate_") as tmp_dir:
        tmp_path = Path(tmp_dir)
        src_path = tmp_path / "arm_win3_runner.c"
        elf_path = tmp_path / "arm_win3_runner.elf"
        bin_path = tmp_path / "arm_win3_runner.bin"
        linker_script = tmp_path / "arm_win3_runner.ld"
        src_path.write_text(generate_arm_source(payloads, profile, readback_mode), encoding="utf-8")
        write_linker_script(linker_script, profile)
        return compile_arm_binary(src_path, elf_path, bin_path, linker_script, profile)


def execute_payloads_chunked(payloads: list[dict], xsdb_retries: int, profile: MemoryProfile, readback_mode: str) -> list[dict]:
    size_cache: dict[tuple[int, ...], int] = {}

    def payload_key(chunk_payloads: list[dict]) -> tuple[int, ...]:
        return tuple(int(payload["output_channel"]) for payload in chunk_payloads)

    def get_program_size(chunk_payloads: list[dict]) -> int:
        key = payload_key(chunk_payloads)
        if key not in size_cache:
            size_cache[key] = estimate_program_size(chunk_payloads, profile, readback_mode)
        return size_cache[key]

    chunk_results: list[dict] = []
    start = 0
    total = len(payloads)
    while start < total:
        remaining = payloads[start:]
        low = 1
        high = len(remaining)
        best_len = 0
        best_size = 0
        while low <= high:
            mid = (low + high) // 2
            try:
                program_size = get_program_size(remaining[:mid])
            except RuntimeError as exc:
                message = str(exc)
                if "ARM program too large" not in message and "ARM mailbox too large" not in message:
                    raise
                high = mid - 1
                continue
            best_len = mid
            best_size = program_size
            low = mid + 1

        if best_len == 0:
            raise RuntimeError(
                f"Unable to fit even one output channel into current OCM execution window at index {start}."
            )

        current_chunk = remaining[:best_len]
        chunk_result = execute_payload_chunk(
            current_chunk,
            xsdb_retries=xsdb_retries,
            profile=profile,
            readback_mode=readback_mode,
        )
        if chunk_result["program_size"] != best_size:
            raise RuntimeError(
                "ARM chunk size estimate diverged from execution compile size.\n"
                f"estimated={best_size}\n"
                f"executed={chunk_result['program_size']}\n"
                f"channels={[payload['output_channel'] for payload in current_chunk]}\n"
            )
        chunk_results.append(chunk_result)
        start += best_len

    return chunk_results


def main() -> None:
    args = parse_args()
    profile = MEMORY_PROFILES[args.memory_profile]
    interpreter = load_interpreter(args.model)
    image_q = load_quantized_input(args.image)
    output_channels = parse_output_channels(args)
    payloads = []
    for output_channel in output_channels:
        payloads.append(
            build_run_payload(
                interpreter=interpreter,
                layer_name=args.layer,
                image_q=image_q,
                output_channel=output_channel,
                output_row=args.output_row,
                start_col=0,
                full_row=args.full_row,
            )
        )

    chunk_results = execute_payloads_chunked(
        payloads,
        xsdb_retries=args.xsdb_retries,
        profile=profile,
        readback_mode=args.readback_mode,
    )
    board_rows_int32: list[list[int]] = []
    board_rows_int8_q: list[list[int]] = []
    board_row_summaries: list[dict] = []
    chunk_program_sizes = [chunk["program_size"] for chunk in chunk_results]
    chunk_statuses = [chunk["mailbox"][15] for chunk in chunk_results]
    chunk_channel_counts = [len(chunk["payloads"]) for chunk in chunk_results]
    chunk_channel_ranges = [
        (chunk["payloads"][0]["output_channel"], chunk["payloads"][-1]["output_channel"])
        for chunk in chunk_results
    ]
    total_case_count = sum(chunk["mailbox"][10] for chunk in chunk_results)
    width = len(payloads[0]["final_row_int32"])
    for chunk in chunk_results:
        board_rows_int32.extend(chunk["board_rows_int32"])
        board_rows_int8_q.extend(chunk["board_rows_int8_q"])
        board_row_summaries.extend(chunk["board_row_summaries"])

    print(f"LAYER {payloads[0]['layer_name']}")
    print(f"IMAGE {args.image}")
    print(f"OUTPUT_CHANNELS {output_channels}")
    print(f"OUTPUT_ROW {args.output_row}")
    print(f"FULL_ROW {int(args.full_row)}")
    print(f"ARM_MEMORY_PROFILE {profile.name}")
    print(f"ARM_READBACK_MODE {args.readback_mode}")
    print(f"ARM_LOAD_ADDR 0x{profile.load_addr:08X}")
    print(f"ARM_MAILBOX_BASE 0x{profile.mailbox_base:08X}")
    print(f"ARM_STACK_ADDR 0x{profile.stack_addr:08X}")
    print(f"INPUT_SHAPE {payloads[0]['input_shape']}")
    print(f"OUTPUT_SHAPE {payloads[0]['output_shape']}")
    print(f"ARM_CHUNK_COUNT {len(chunk_results)}")
    print(f"ARM_CHUNK_CHANNEL_COUNTS {chunk_channel_counts}")
    print(f"ARM_CHUNK_CHANNEL_RANGES {chunk_channel_ranges}")
    print(f"ARM_CHUNK_PROGRAM_BYTES {chunk_program_sizes}")
    print(f"ARM_PROGRAM_BYTES_MAX {max(chunk_program_sizes)}")
    print(f"ARM_CASE_COUNT {total_case_count}")
    print(f"ARM_CHANNEL_COUNT {len(payloads)}")
    print(f"ARM_ROW_WIDTH {width}")
    print(f"ARM_WIN3_STATUS_LIST {[f'0x{status:08X}' for status in chunk_statuses]}")
    verbose_rows = len(payloads) <= 8 and args.readback_mode == "full"
    for index, payload in enumerate(payloads):
        print(f"OUTPUT_CHANNEL {payload['output_channel']}")
        print(f"START_COL {payload['start_col']}")
        print(f"ADJUSTED_BIAS {payload['adjusted_bias']}")
        if args.readback_mode == "summary":
            expected_row = payload["final_row_int32"]
            expected_summary = {
                "int32_hash": fnv1a_hash_int32_row(expected_row),
                "int32_sum": sum(expected_row),
                "int32_min": min(expected_row),
                "int32_max": max(expected_row),
            }
            print(f"ARM_BOARD_ROW_SUMMARY {board_row_summaries[index]}")
            print(f"ROW_SUMMARY_GOLDEN {expected_summary}")
        elif verbose_rows:
            board_row_int32 = board_rows_int32[index]
            board_row_int8_q = board_rows_int8_q[index]
            print(f"FINAL_ROW_INT32_GOLDEN {payload['final_row_int32']}")
            print(f"ARM_BOARD_FINAL_ROW_INT32 {board_row_int32}")
            print(f"FINAL_ROW_INT8_Q_GOLDEN {payload['final_row_int8_q']}")
            print(f"ARM_BOARD_FINAL_ROW_INT8_Q {board_row_int8_q}")
            print(f"TFLITE_OUTPUT_Q_ROW {payload['tflite_row_q']}")
        else:
            board_row_int32 = board_rows_int32[index]
            board_row_int8_q = board_rows_int8_q[index]
            int32_crc = zlib.crc32(np.asarray(board_row_int32, dtype=np.int32).tobytes()) & 0xFFFFFFFF
            int8_crc = zlib.crc32(np.asarray(board_row_int8_q, dtype=np.int8).tobytes()) & 0xFFFFFFFF
            print(
                "ROW_SUMMARY "
                f"INT32_CRC=0x{int32_crc:08X} "
                f"INT32_SUM={sum(board_row_int32)} "
                f"INT32_MIN={min(board_row_int32)} "
                f"INT32_MAX={max(board_row_int32)} "
                f"INT8_CRC=0x{int8_crc:08X} "
                f"INT8_SUM={sum(board_row_int8_q)} "
                f"FIRST3_INT32={board_row_int32[:3]} "
                f"LAST3_INT32={board_row_int32[-3:]}"
            )

    if args.full_row:
        print("WIN3_REAL_LAYER_ARM_FULL_ROW_PASS")
    else:
        print("WIN3_REAL_LAYER_ARM_TILE_PASS")


if __name__ == "__main__":
    main()
