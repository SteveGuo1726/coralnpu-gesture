# PROJECT_LOCAL_SELF_RESEARCH_NOT_GOOGLE_OFFICIAL
# Isolated full-build wrapper. Reuses the audited descriptor build flow but
# changes only the input-window configuration and artifact names.
set wrapper_dir [file dirname [file normalize [info script]]]
set base_script [file join $wrapper_dir build_gestureflow_layer_chain_hp0_7020.tcl]
set fd [open $base_script r]
set body [read $fd]
close $fd
set body [string map [list \
  "CONFIG.MAX_INPUT_CHANNELS {40}" "CONFIG.MAX_INPUT_CHANNELS {80}" \
  "CONFIG.ENABLE_POSTPROCESS {0}" "CONFIG.ENABLE_POSTPROCESS {1}" \
  "gestureflow_layer_chain_descriptor_hp0_7020_utilization_impl.rpt" "gestureflow_wide80_7020_utilization_impl.rpt" \
  "gestureflow_layer_chain_descriptor_hp0_7020_timing_impl.rpt" "gestureflow_wide80_7020_timing_impl.rpt" \
  "gestureflow_layer_chain_descriptor_hp0_7020.xsa" "gestureflow_wide80_7020.xsa" \
  "gestureflow_layer_chain_descriptor_hp0_7020.bit" "gestureflow_wide80_7020.bit" \
  "GESTUREFLOW_LAYER_CHAIN_DESCRIPTOR_HP0_7020_BITSTREAM_PASS" "GESTUREFLOW_WIDE80_7020_BITSTREAM_PASS" \
] $body]
eval $body
