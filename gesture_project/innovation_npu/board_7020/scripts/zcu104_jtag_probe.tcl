# PROJECT_LOCAL_SELF_RESEARCH_NOT_GOOGLE_OFFICIAL
# Minimal ZCU104 JTAG health probe: connect to hw_server, enumerate the scan
# chain, then try to select the ZynqMP DAP/APU targets if they are visible.

puts "ZCU104_JTAG_PROBE_BEGIN"
connect

puts "ZCU104_JTAG_CHAIN_BEGIN"
jtag targets
puts "ZCU104_JTAG_CHAIN_END"

puts "ZCU104_TARGETS_BEGIN"
targets
puts "ZCU104_TARGETS_END"

if {![catch {targets -set -nocase -filter {name =~ "*PSU*"}} err]} {
    puts "ZCU104_PSU_SELECT_PASS"
} else {
    puts "ZCU104_PSU_SELECT_FAIL=$err"
}

disconnect
puts "ZCU104_JTAG_PROBE_END"
exit
