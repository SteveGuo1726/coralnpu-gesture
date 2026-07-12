set base_addr 0x43C00000
set bit_file "E:/coralnpu_vivado/zynqmini_7z010/rowhandoff_ps_csr_build/rowhandoff_ps_csr.bit"
set ps7_init_file "E:/coralnpu_vivado/zynqmini_7z010/rowhandoff_ps_csr_build/rowhandoff_ps_csr_build.gen/sources_1/bd/design_1/ip/design_1_processing_system7_0_0/ps7_init.tcl"

if {$argc > 0} {
  set bit_file [lindex $argv 0]
}

proc read32 {addr} {
  set value [mrd -force -value $addr]
  return [format "0x%08X" $value]
}

proc read32_int {addr} {
  return [mrd -force -value $addr]
}

proc expect32 {name value expected} {
  if {$value != $expected} {
    error [format "%s expected 0x%08X, got 0x%08X" $name $expected $value]
  }
}

proc dump_and_check_rowhandoff_csr {base_addr} {
  set magic [read32_int $base_addr]
  set version [read32_int [expr {$base_addr + 0x04}]]
  set control [read32_int [expr {$base_addr + 0x08}]]
  set cycle0 [read32_int [expr {$base_addr + 0x0C}]]
  after 200
  set cycle1 [read32_int [expr {$base_addr + 0x0C}]]
  set hit [read32_int [expr {$base_addr + 0x10}]]
  set miss [read32_int [expr {$base_addr + 0x14}]]
  set invalidate [read32_int [expr {$base_addr + 0x18}]]
  set produce [read32_int [expr {$base_addr + 0x1C}]]
  set tail_hit [read32_int [expr {$base_addr + 0x20}]]
  set interior [read32_int [expr {$base_addr + 0x24}]]
  set right_edge [read32_int [expr {$base_addr + 0x28}]]
  set row_last [read32_int [expr {$base_addr + 0x2C}]]
  set trace_replay [read32_int [expr {$base_addr + 0x3C}]]

  puts "MAGIC [format "0x%08X" $magic]"
  puts "VERSION [format "0x%08X" $version]"
  puts "CONTROL [format "0x%08X" $control]"
  puts "CYCLE0 [format "0x%08X" $cycle0]"
  puts "CYCLE1 [format "0x%08X" $cycle1]"
  puts "HIT [format "0x%08X" $hit]"
  puts "MISS [format "0x%08X" $miss]"
  puts "INVALIDATE [format "0x%08X" $invalidate]"
  puts "PRODUCE [format "0x%08X" $produce]"
  puts "TAIL_HIT [format "0x%08X" $tail_hit]"
  puts "INTERIOR [format "0x%08X" $interior]"
  puts "RIGHT_EDGE [format "0x%08X" $right_edge]"
  puts "ROW_LAST [format "0x%08X" $row_last]"
  puts "TRACE_WORD [read32 [expr {$base_addr + 0x30}]]"
  puts "TRACE_AUX [read32 [expr {$base_addr + 0x34}]]"
  puts "ROW_STATE [read32 [expr {$base_addr + 0x38}]]"
  puts "TRACE_REPLAY [format "0x%08X" $trace_replay]"

  if {$magic != 0x52484F57} {
    error [format "Unexpected magic: 0x%08X" $magic]
  }
  if {$version != 0x20260710} {
    error [format "Unexpected version: 0x%08X" $version]
  }
  if {$cycle1 == $cycle0} {
    error [format "Cycle counter did not advance: 0x%08X" $cycle0]
  }

  if {($control & 0x8) != 0} {
    if {($trace_replay & 0x00008000) == 0} {
      error [format "Trace replay not done: 0x%08X" $trace_replay]
    }
    expect32 HIT $hit 21
    expect32 MISS $miss 1
    expect32 INVALIDATE $invalidate 1
    expect32 PRODUCE $produce 22
    expect32 TAIL_HIT $tail_hit 21
    expect32 INTERIOR $interior 22
    expect32 RIGHT_EDGE $right_edge 22
    expect32 ROW_LAST $row_last 45
    puts "ROWHANDOFF_WORKLOAD_TRACE_REPLAY_COUNTS_PASS"
  }
}

proc select_target_by_name {pattern} {
  targets -set -filter "name =~ {$pattern}"
}

connect
puts "ROWHANDOFF_CSR_READBACK_TARGETS_BEGIN"
puts [targets]
puts "ROWHANDOFF_CSR_READBACK_TARGETS_END"

select_target_by_name "ARM Cortex-A9 MPCore #0"

puts "ROWHANDOFF_CSR_READBACK_TRY_EXISTING"
set existing_status [catch {
  dump_and_check_rowhandoff_csr $base_addr
} existing_msg]

if {$existing_status == 0} {
  puts "ROWHANDOFF_CSR_READBACK_EXISTING_PASS"
  exit
}

puts "ROWHANDOFF_CSR_READBACK_EXISTING_FAIL $existing_msg"

if {![file exists $bit_file]} {
  error "Bitstream file does not exist: $bit_file"
}
if {![file exists $ps7_init_file]} {
  error "PS7 init file does not exist: $ps7_init_file"
}

puts "ROWHANDOFF_CSR_READBACK_PROGRAM_FPGA $bit_file"
select_target_by_name "xc7z010"
fpga -file $bit_file
after 500

puts "ROWHANDOFF_CSR_READBACK_INIT_PS7"
source $ps7_init_file
catch {
  select_target_by_name "ARM Cortex-A9 MPCore #0"
  stop
  ps7_init
  ps7_post_config
}

dump_and_check_rowhandoff_csr $base_addr
puts "ROWHANDOFF_CSR_READBACK_PASS"
exit
