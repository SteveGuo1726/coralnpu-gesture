"""核心 3x3 层握手契约 / 寄存器表 / 伪 RTL 通用生成逻辑。"""

from __future__ import annotations

from typing import Any


def sv_int_width(max_value: int) -> int:
    width = 1
    while (1 << width) <= max_value:
        width += 1
    return width


def layer_tag(layer_name: str) -> str:
    return layer_name.replace("-", "_")


def build_contract(schedule: dict[str, Any]) -> dict[str, Any]:
    tiles_y = int(schedule["grid"]["tiles_y"])
    tiles_x = int(schedule["grid"]["tiles_x"])
    tiles_oc = int(schedule["grid"]["tiles_oc"])
    tile_acc_bytes = int(schedule["writeback"]["tile_acc_bytes"])
    tile_output_bytes = int(schedule["writeback"]["tile_output_bytes"])

    return {
        "layer_name": schedule["layer_name"],
        "shape": schedule["shape"],
        "config": schedule["config"],
        "grid": schedule["grid"],
        "resources": [
            {
                "name": "input_port",
                "serves": ["line_fill", "window_shift", "row_advance"],
                "sharing_rule": "同一时刻仅允许 1 个输入类请求在飞。",
            },
            {
                "name": "weight_port",
                "serves": ["weight_preload", "weight_group_load_reload"],
                "sharing_rule": "同一时刻仅允许 1 个外部 weight 请求在飞。",
            },
            {
                "name": "weight_bank",
                "serves": ["weight_group_select_row_resident"],
                "sharing_rule": "row-resident 模式下仅做本地组选择，不占外部带宽。",
            },
            {
                "name": "compute_array",
                "serves": ["compute_acc"],
                "sharing_rule": "同一时刻仅计算 1 个 tile oc_group。",
            },
            {
                "name": "output_port",
                "serves": ["quant_writeback"],
                "sharing_rule": f"同一时刻仅写回 1 个 {tile_output_bytes} B 输出 tile。",
            },
        ],
        "handshake_channels": [
            {
                "op": "line_fill",
                "resource": "input_port",
                "request": "line_fill_req",
                "ready": "line_fill_ready",
                "done": "line_fill_done",
                "payload": {
                    "bytes": int(schedule["line_fill"]["first_spatial_site_bytes"]),
                    "target": "首个 spatial tile / 新 tile-row 初始化",
                },
            },
            {
                "op": "window_shift",
                "resource": "input_port",
                "request": "window_shift_req",
                "ready": "window_shift_ready",
                "done": "window_shift_done",
                "payload": {
                    "bytes": int(schedule["x_shift"]["new_bytes_per_shift"]),
                    "target": "同一 out_y_tile 内横向推进",
                },
            },
            {
                "op": "row_advance",
                "resource": "input_port",
                "request": "row_advance_req",
                "ready": "row_advance_ready",
                "done": "row_advance_done",
                "payload": {
                    "bytes": int(schedule["y_advance"]["new_bytes_per_advance"]),
                    "target": "切到下一条 out_y_tile",
                },
            },
            {
                "op": "weight_preload",
                "resource": "weight_port",
                "request": "weight_preload_req",
                "ready": "weight_preload_ready",
                "done": "weight_preload_done",
                "payload": {
                    "bytes": int(schedule["weight_schedule"]["weights_per_spatial_site"]),
                    "target": f"整条 tile-row 的 {tiles_oc} 组 oc_tile weight",
                },
            },
            {
                "op": "weight_group_load_reload",
                "resource": "weight_port",
                "request": "weight_group_load_req",
                "ready": "weight_group_load_ready",
                "done": "weight_group_load_done",
                "payload": {
                    "bytes": int(schedule["weight_schedule"]["weight_tile_bytes"]),
                    "target": "reload 策略下当前 oc_group 的外部 weight tile",
                },
            },
            {
                "op": "weight_group_select_row_resident",
                "resource": "weight_bank",
                "request": "weight_group_load_req",
                "ready": "weight_group_select_ready",
                "done": "weight_group_select_done",
                "payload": {
                    "bytes": 0,
                    "target": "row-resident 策略下本地 weight bank 选中当前 oc_group",
                },
            },
            {
                "op": "compute_acc",
                "resource": "compute_array",
                "request": "compute_req",
                "ready": "compute_ready",
                "done": "compute_done",
                "payload": {
                    "tile_acc_bytes": tile_acc_bytes,
                    "target": "当前 tile oc_group 的 int32 accumulator 更新",
                },
            },
            {
                "op": "quant_writeback",
                "resource": "output_port",
                "request": "quant_write_req",
                "ready": "quant_write_ready",
                "done": "quant_write_done",
                "payload": {
                    "bytes": tile_output_bytes,
                    "target": "当前 oc_group 的 int8 输出写回",
                },
            },
        ],
        "state_registers": [
            {"name": "state_q", "role": "顶层 FSM 当前状态"},
            {"name": "out_y_tile_q", "role": f"0..{tiles_y - 1}，标记当前 tile-row"},
            {"name": "out_x_tile_q", "role": f"0..{tiles_x - 1}，标记当前 tile-col"},
            {"name": "oc_group_q", "role": f"0..{tiles_oc - 1}，标记当前输出通道组"},
        ],
        "valid_bits": [
            {"name": "line_buffer_valid", "set_by": ["line_fill_done", "row_advance_done"]},
            {"name": "window_valid", "set_by": ["line_fill_done", "window_shift_done", "row_advance_done"]},
            {"name": "weight_row_valid", "set_by": ["weight_preload_done"], "clear_on": ["next tile-row start"]},
            {"name": "weight_group_valid", "set_by": ["weight_group_load_done", "weight_group_select_done"]},
            {"name": "acc_valid", "set_by": ["compute_done"], "clear_on": ["quant_write_done"]},
        ],
        "state_dependencies": [
            {
                "state": "S4_COMPUTE_ACC",
                "requires": ["window_valid", "weight_group_valid"],
                "extra_rule": "row-resident 模式额外要求 weight_row_valid=1。",
            },
            {
                "state": "S5_QUANTIZE_WRITEBACK",
                "requires": ["acc_valid"],
                "extra_rule": "写回完成后才能进入分支判断。",
            },
            {
                "state": "S7_WINDOW_SHIFT",
                "requires": [f"当前 spatial tile 的 {tiles_oc} 个 oc_group 已写回完成"],
                "extra_rule": "仍复用左侧历史输入列。",
            },
            {
                "state": "S8_ADVANCE_ROW",
                "requires": [f"当前 tile-row 的 {tiles_x} 个 spatial tile 已写回完成"],
                "extra_rule": "仍复用旧 2 行输入。",
            },
        ],
        "strategy_rules": {
            "reload": {
                "weight_policy": "每个 spatial tile / oc_group 都走外部 weight_group_load。",
                "expected_weight_bytes": int(schedule["weight_schedule"]["total_weight_bytes_naive"]),
            },
            "row_resident": {
                "weight_policy": "每个 out_y_tile 先 weight_preload，后续 oc_group 只做本地组选择。",
                "expected_weight_bytes": int(schedule["weight_schedule"]["total_weight_bytes_row_resident"]),
            },
        },
    }


def build_register_table(contract: dict[str, Any]) -> dict[str, Any]:
    tiles_y = int(contract["grid"]["tiles_y"])
    tiles_x = int(contract["grid"]["tiles_x"])
    tiles_oc = int(contract["grid"]["tiles_oc"])

    state_rows = [
        {
            "state": "S0_IDLE",
            "entry_actions": ["清零 out_y_tile_q/out_x_tile_q/oc_group_q", "清零所有 valid 位"],
            "exit_condition": "layer_start",
            "next_state": "S1_PRELOAD_WEIGHTS 或 S2_FILL_FIRST_TILE",
        },
        {
            "state": "S1_PRELOAD_WEIGHTS",
            "entry_actions": ["拉起 weight_preload_req", "等待 weight_preload_done"],
            "exit_condition": "weight_preload_done",
            "next_state": "S2_FILL_FIRST_TILE 或 S3_LOAD_WEIGHT_GROUP",
            "valid_updates": ["weight_row_valid <= 1", "weight_group_valid <= 0"],
        },
        {
            "state": "S2_FILL_FIRST_TILE",
            "entry_actions": ["拉起 line_fill_req", "等待 line_fill_done"],
            "exit_condition": "line_fill_done",
            "next_state": "S3_LOAD_WEIGHT_GROUP",
            "valid_updates": [
                "line_buffer_valid <= 1",
                "window_valid <= 1",
                "weight_group_valid <= 0",
                "acc_valid <= 0",
            ],
        },
        {
            "state": "S3_LOAD_WEIGHT_GROUP",
            "entry_actions": ["拉起 weight_group_load_req", "等待 weight_group_load_done 或 weight_group_select_done"],
            "exit_condition": "weight_group_load_done or weight_group_select_done",
            "next_state": "S4_COMPUTE_ACC",
            "valid_updates": ["weight_group_valid <= 1"],
        },
        {
            "state": "S4_COMPUTE_ACC",
            "entry_actions": ["检查 window_valid/weight_group_valid", "拉起 compute_req", "等待 compute_done"],
            "exit_condition": "compute_done",
            "next_state": "S5_QUANTIZE_WRITEBACK",
            "valid_updates": ["acc_valid <= 1"],
        },
        {
            "state": "S5_QUANTIZE_WRITEBACK",
            "entry_actions": ["检查 acc_valid", "拉起 quant_write_req", "等待 quant_write_done"],
            "exit_condition": "quant_write_done",
            "next_state": "S6_NEXT_OC_OR_SHIFT",
            "counter_updates": ["oc_group_q 保持给 S6 判断"],
            "valid_updates": ["acc_valid <= 0"],
        },
        {
            "state": "S6_NEXT_OC_OR_SHIFT",
            "entry_actions": ["比较 oc_group_q / out_x_tile_q / out_y_tile_q"],
            "exit_condition": "组合判断完成",
            "next_state": "S3_LOAD_WEIGHT_GROUP 或 S7_WINDOW_SHIFT 或 S8_ADVANCE_ROW 或 S9_DONE",
            "counter_updates": [
                "若 oc_group_q 未完成，则 oc_group_q <= oc_group_q + 1",
                "若切列，则 out_x_tile_q <= out_x_tile_q + 1 且 oc_group_q <= 0",
                "若切行，则 out_y_tile_q <= out_y_tile_q + 1, out_x_tile_q <= 0, oc_group_q <= 0",
            ],
        },
        {
            "state": "S7_WINDOW_SHIFT",
            "entry_actions": ["拉起 window_shift_req", "等待 window_shift_done"],
            "exit_condition": "window_shift_done",
            "next_state": "S3_LOAD_WEIGHT_GROUP",
            "valid_updates": ["window_valid <= 1", "weight_group_valid <= 0", "acc_valid <= 0"],
        },
        {
            "state": "S8_ADVANCE_ROW",
            "entry_actions": ["拉起 row_advance_req", "等待 row_advance_done"],
            "exit_condition": "row_advance_done",
            "next_state": "S1_PRELOAD_WEIGHTS 或 S3_LOAD_WEIGHT_GROUP",
            "valid_updates": [
                "line_buffer_valid <= 1",
                "window_valid <= 1",
                "weight_group_valid <= 0",
                "acc_valid <= 0",
                "weight_row_valid <= 0",
            ],
        },
        {
            "state": "S9_DONE",
            "entry_actions": ["拉起 done_pulse"],
            "exit_condition": "done_pulse 发出",
            "next_state": "S0_IDLE",
        },
    ]

    return {
        "layer_name": contract["layer_name"],
        "shape": contract["shape"],
        "grid": {"tiles_y": tiles_y, "tiles_x": tiles_x, "tiles_oc": tiles_oc},
        "state_rows": state_rows,
        "registers": contract["state_registers"],
        "valid_bits": contract["valid_bits"],
    }


def contract_markdown(contract: dict[str, Any]) -> str:
    lines = [
        f"# {contract['layer_name']} {contract['config']['row_tile']}x{contract['config']['col_tile']}x{contract['config']['oc_tile']} 握手级接口契约",
        "",
        f"- 层：`{contract['layer_name']}`",
        f"- 形状：`{contract['shape']}`",
        "",
        "## 资源域",
        "",
        "| 资源 | 服务对象 | 共享规则 |",
        "| --- | --- | --- |",
    ]

    for resource in contract["resources"]:
        lines.append(
            "| `{name}` | {serves} | {rule} |".format(
                name=resource["name"],
                serves=", ".join(f"`{item}`" for item in resource["serves"]),
                rule=resource["sharing_rule"],
            )
        )

    lines.extend(
        [
            "",
            "## 握手通道",
            "",
            "| op | resource | req | ready | done | payload |",
            "| --- | --- | --- | --- | --- | --- |",
        ]
    )

    for channel in contract["handshake_channels"]:
        payload_desc = ", ".join(f"{k}={v}" for k, v in channel["payload"].items())
        lines.append(
            "| `{op}` | `{resource}` | `{request}` | `{ready}` | `{done}` | {payload_desc} |".format(
                op=channel["op"],
                resource=channel["resource"],
                request=channel["request"],
                ready=channel["ready"],
                done=channel["done"],
                payload_desc=payload_desc,
            )
        )

    lines.extend(
        [
            "",
            "## Valid Bit",
            "",
            "| 名称 | set 条件 | clear 条件 |",
            "| --- | --- | --- |",
        ]
    )

    for item in contract["valid_bits"]:
        lines.append(
            "| `{name}` | {set_by} | {clear_on} |".format(
                name=item["name"],
                set_by=", ".join(f"`{v}`" for v in item["set_by"]),
                clear_on=", ".join(f"`{v}`" for v in item.get("clear_on", ["-"])),
            )
        )

    lines.extend(
        [
            "",
            "## 状态依赖",
            "",
            "| 状态 | requires | 额外规则 |",
            "| --- | --- | --- |",
        ]
    )

    for dep in contract["state_dependencies"]:
        lines.append(
            "| `{state}` | {requires} | {extra_rule} |".format(
                state=dep["state"],
                requires=", ".join(f"`{v}`" for v in dep["requires"]),
                extra_rule=dep["extra_rule"],
            )
        )

    return "\n".join(lines) + "\n"


def register_table_markdown(table: dict[str, Any]) -> str:
    lines = [
        f"# {table['layer_name']} {table['grid']['tiles_y']}x{table['grid']['tiles_x']}x{table['grid']['tiles_oc']} 寄存器传输更新表",
        "",
        "| 状态 | entry 动作 | exit 条件 | 计数器更新 | valid 更新 | 下一状态 |",
        "| --- | --- | --- | --- | --- | --- |",
    ]

    for row in table["state_rows"]:
        lines.append(
            "| `{state}` | {entry} | `{exit_}` | {counter} | {valid} | `{next_}` |".format(
                state=row["state"],
                entry="<br>".join(row.get("entry_actions", ["-"])),
                exit_=row.get("exit_condition", "-"),
                counter="<br>".join(row.get("counter_updates", ["-"])),
                valid="<br>".join(row.get("valid_updates", ["-"])),
                next_=row.get("next_state", "-"),
            )
        )

    return "\n".join(lines) + "\n"


def pseudo_sv_text(contract: dict[str, Any], table: dict[str, Any]) -> str:
    tag = layer_tag(contract["layer_name"])
    tiles_y = int(contract["grid"]["tiles_y"])
    tiles_x = int(contract["grid"]["tiles_x"])
    tiles_oc = int(contract["grid"]["tiles_oc"])
    y_w = sv_int_width(max(tiles_y - 1, 0))
    x_w = sv_int_width(max(tiles_x - 1, 0))
    oc_w = sv_int_width(max(tiles_oc - 1, 0))
    row_tile = int(contract["config"]["row_tile"])
    col_tile = int(contract["config"]["col_tile"])
    oc_tile = int(contract["config"]["oc_tile"])

    return f"""module {tag}_ctrl_{row_tile}x{col_tile}x{oc_tile} (
  input  logic clk,
  input  logic rst_n,
  input  logic layer_start,
  input  logic line_fill_done,
  input  logic window_shift_done,
  input  logic row_advance_done,
  input  logic weight_preload_done,
  input  logic weight_group_load_done,
  input  logic weight_group_select_done,
  input  logic compute_done,
  input  logic quant_write_done,
  output logic line_fill_req,
  output logic window_shift_req,
  output logic row_advance_req,
  output logic weight_preload_req,
  output logic weight_group_load_req,
  output logic compute_req,
  output logic quant_write_req,
  output logic done_pulse
);

  typedef enum logic [3:0] {{
    S0_IDLE,
    S1_PRELOAD_WEIGHTS,
    S2_FILL_FIRST_TILE,
    S3_LOAD_WEIGHT_GROUP,
    S4_COMPUTE_ACC,
    S5_QUANTIZE_WRITEBACK,
    S6_NEXT_OC_OR_SHIFT,
    S7_WINDOW_SHIFT,
    S8_ADVANCE_ROW,
    S9_DONE
  }} state_t;

  state_t state_q, state_d;
  logic [{y_w - 1}:0] out_y_tile_q, out_y_tile_d;
  logic [{x_w - 1}:0] out_x_tile_q, out_x_tile_d;
  logic [{oc_w - 1}:0] oc_group_q, oc_group_d;

  logic line_buffer_valid_q, line_buffer_valid_d;
  logic window_valid_q, window_valid_d;
  logic weight_row_valid_q, weight_row_valid_d;
  logic weight_group_valid_q, weight_group_valid_d;
  logic acc_valid_q, acc_valid_d;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state_q <= S0_IDLE;
      out_y_tile_q <= '0;
      out_x_tile_q <= '0;
      oc_group_q <= '0;
      line_buffer_valid_q <= 1'b0;
      window_valid_q <= 1'b0;
      weight_row_valid_q <= 1'b0;
      weight_group_valid_q <= 1'b0;
      acc_valid_q <= 1'b0;
    end else begin
      state_q <= state_d;
      out_y_tile_q <= out_y_tile_d;
      out_x_tile_q <= out_x_tile_d;
      oc_group_q <= oc_group_d;
      line_buffer_valid_q <= line_buffer_valid_d;
      window_valid_q <= window_valid_d;
      weight_row_valid_q <= weight_row_valid_d;
      weight_group_valid_q <= weight_group_valid_d;
      acc_valid_q <= acc_valid_d;
    end
  end

  always_comb begin
    state_d = state_q;
    out_y_tile_d = out_y_tile_q;
    out_x_tile_d = out_x_tile_q;
    oc_group_d = oc_group_q;
    line_buffer_valid_d = line_buffer_valid_q;
    window_valid_d = window_valid_q;
    weight_row_valid_d = weight_row_valid_q;
    weight_group_valid_d = weight_group_valid_q;
    acc_valid_d = acc_valid_q;

    line_fill_req = 1'b0;
    window_shift_req = 1'b0;
    row_advance_req = 1'b0;
    weight_preload_req = 1'b0;
    weight_group_load_req = 1'b0;
    compute_req = 1'b0;
    quant_write_req = 1'b0;
    done_pulse = 1'b0;

    unique case (state_q)
      S0_IDLE: begin
        line_buffer_valid_d = 1'b0;
        window_valid_d = 1'b0;
        weight_row_valid_d = 1'b0;
        weight_group_valid_d = 1'b0;
        acc_valid_d = 1'b0;
        out_y_tile_d = '0;
        out_x_tile_d = '0;
        oc_group_d = '0;
        if (layer_start) state_d = S1_PRELOAD_WEIGHTS;
      end

      S1_PRELOAD_WEIGHTS: begin
        weight_preload_req = 1'b1;
        if (weight_preload_done) begin
          weight_row_valid_d = 1'b1;
          weight_group_valid_d = 1'b0;
          if ((out_y_tile_q == '0) && (out_x_tile_q == '0) && (oc_group_q == '0)) begin
            state_d = S2_FILL_FIRST_TILE;
          end else begin
            state_d = S3_LOAD_WEIGHT_GROUP;
          end
        end
      end

      S2_FILL_FIRST_TILE: begin
        line_fill_req = 1'b1;
        if (line_fill_done) begin
          line_buffer_valid_d = 1'b1;
          window_valid_d = 1'b1;
          weight_group_valid_d = 1'b0;
          acc_valid_d = 1'b0;
          state_d = S3_LOAD_WEIGHT_GROUP;
        end
      end

      S3_LOAD_WEIGHT_GROUP: begin
        weight_group_load_req = 1'b1;
        if (weight_group_load_done || weight_group_select_done) begin
          weight_group_valid_d = 1'b1;
          state_d = S4_COMPUTE_ACC;
        end
      end

      S4_COMPUTE_ACC: begin
        if (window_valid_q && weight_group_valid_q && weight_row_valid_q) begin
          compute_req = 1'b1;
          if (compute_done) begin
            acc_valid_d = 1'b1;
            state_d = S5_QUANTIZE_WRITEBACK;
          end
        end
      end

      S5_QUANTIZE_WRITEBACK: begin
        if (acc_valid_q) begin
          quant_write_req = 1'b1;
          if (quant_write_done) begin
            acc_valid_d = 1'b0;
            state_d = S6_NEXT_OC_OR_SHIFT;
          end
        end
      end

      S6_NEXT_OC_OR_SHIFT: begin
        if (oc_group_q < {tiles_oc - 1}) begin
          oc_group_d = oc_group_q + 1'b1;
          state_d = S3_LOAD_WEIGHT_GROUP;
        end else if (out_x_tile_q < {tiles_x - 1}) begin
          out_x_tile_d = out_x_tile_q + 1'b1;
          oc_group_d = '0;
          state_d = S7_WINDOW_SHIFT;
        end else if (out_y_tile_q < {tiles_y - 1}) begin
          out_y_tile_d = out_y_tile_q + 1'b1;
          out_x_tile_d = '0;
          oc_group_d = '0;
          state_d = S8_ADVANCE_ROW;
        end else begin
          state_d = S9_DONE;
        end
      end

      S7_WINDOW_SHIFT: begin
        window_shift_req = 1'b1;
        if (window_shift_done) begin
          window_valid_d = 1'b1;
          weight_group_valid_d = 1'b0;
          acc_valid_d = 1'b0;
          state_d = S3_LOAD_WEIGHT_GROUP;
        end
      end

      S8_ADVANCE_ROW: begin
        row_advance_req = 1'b1;
        if (row_advance_done) begin
          line_buffer_valid_d = 1'b1;
          window_valid_d = 1'b1;
          weight_group_valid_d = 1'b0;
          acc_valid_d = 1'b0;
          weight_row_valid_d = 1'b0;
          state_d = S1_PRELOAD_WEIGHTS;
        end
      end

      S9_DONE: begin
        done_pulse = 1'b1;
        state_d = S0_IDLE;
      end
    endcase
  end

endmodule
"""
