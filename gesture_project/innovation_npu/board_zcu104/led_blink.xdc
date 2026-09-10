# PROJECT_LOCAL_SELF_RESEARCH_NOT_GOOGLE_OFFICIAL
# ZCU104 board pins from the official XilinxBoardStore zcu104 1.1 board files.

set_property -dict {PACKAGE_PIN AH18 IOSTANDARD DIFF_SSTL12} [get_ports sys_clk_p]
set_property -dict {PACKAGE_PIN AH17 IOSTANDARD DIFF_SSTL12} [get_ports sys_clk_n]
create_clock -period 3.333 -name sys_clk_p [get_ports sys_clk_p]

set_property -dict {PACKAGE_PIN D5 IOSTANDARD LVCMOS33} [get_ports {led[0]}]
set_property -dict {PACKAGE_PIN D6 IOSTANDARD LVCMOS33} [get_ports {led[1]}]
set_property -dict {PACKAGE_PIN A5 IOSTANDARD LVCMOS33} [get_ports {led[2]}]
set_property -dict {PACKAGE_PIN B5 IOSTANDARD LVCMOS33} [get_ports {led[3]}]
