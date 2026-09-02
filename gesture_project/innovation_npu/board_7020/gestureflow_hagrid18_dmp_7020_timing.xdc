# PROJECT_LOCAL_SELF_RESEARCH_NOT_GOOGLE_OFFICIAL
# Timing relaxation for the quasi-static AXI-Lite configuration register
# layer_mode. The PS writes it once per layer (before the CONTROL launch word),
# and it stays constant for the entire layer execution. Vivado nevertheless
# times it as a normal 1-cycle register, which places a 15-level, mostly-routed
# combinational chain (layer_mode -> mode mux -> loader pixel_ready ->
# m_axi_rready -> SmartConnect command FIFO) on the critical path. Because the
# value is stable long before the layer starts, its launch edge is removed from
# timing analysis; dynamic handshake paths starting from pixel_valid/fifo_bytes
# /state are still timed normally.
set_false_path -from [get_cells -hierarchical -filter {NAME =~ "*layer_mode_reg*"}]
