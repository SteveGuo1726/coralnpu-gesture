# PROJECT_LOCAL_SELF_RESEARCH_NOT_GOOGLE_OFFICIAL
# Isolated full-build wrapper for the HaGRID-18 deployment. Reuses the audited
# descriptor build flow but changes only the input-window configuration
# (MAX_INPUT_CHANNELS=48, postprocess on) and artifact names. 18-class student
# max input is 48 channels, so this is narrower than wide80 and saves BRAM.
set wrapper_dir [file dirname [file normalize [info script]]]
set base_script [file join $wrapper_dir build_gestureflow_layer_chain_hp0_7020.tcl]
set fd [open $base_script r]
set body [read $fd]
close $fd
set fclk_mhz 40
if {[info exists ::env(GESTUREFLOW_HAGRID18_FCLK_MHZ)] && $::env(GESTUREFLOW_HAGRID18_FCLK_MHZ) ne ""} {
  set fclk_mhz $::env(GESTUREFLOW_HAGRID18_FCLK_MHZ)
}
# The direct stream writer remains an isolated experiment until it has a
# full-network DDR readback proof. The production 32-lane path keeps the
# board-validated output-bank writer, which is required by the next layer.
set body [string map [list \
  "CONFIG.MAX_INPUT_CHANNELS {40}" "CONFIG.MAX_INPUT_CHANNELS {48}" \
  "CONFIG.ENABLE_POSTPROCESS {0}" "CONFIG.ENABLE_POSTPROCESS {1}" \
  "CONFIG.OUT_LANES {16}" "CONFIG.OUT_LANES {32}" \
  "CONFIG.POOL_BANK_ADDR_W {14}" "CONFIG.POOL_BANK_ADDR_W {12}" \
  "CONFIG.PCW_FPGA0_PERIPHERAL_FREQMHZ {40}" "CONFIG.PCW_FPGA0_PERIPHERAL_FREQMHZ {$fclk_mhz}" \
  "gestureflow_layer_chain_descriptor_hp0_7020_utilization_impl.rpt" "gestureflow_hagrid18_7020_utilization_impl.rpt" \
  "gestureflow_layer_chain_descriptor_hp0_7020_timing_impl.rpt" "gestureflow_hagrid18_7020_timing_impl.rpt" \
  "gestureflow_layer_chain_descriptor_hp0_7020.xsa" "gestureflow_hagrid18_7020.xsa" \
  "gestureflow_layer_chain_descriptor_hp0_7020.bit" "gestureflow_hagrid18_7020.bit" \
  "GESTUREFLOW_LAYER_CHAIN_DESCRIPTOR_HP0_7020_BITSTREAM_PASS" "GESTUREFLOW_HAGRID18_7020_BITSTREAM_PASS" \
] $body]
eval $body
