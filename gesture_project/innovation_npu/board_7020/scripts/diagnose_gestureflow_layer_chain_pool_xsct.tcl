# PROJECT_LOCAL_SELF_RESEARCH_NOT_GOOGLE_OFFICIAL
connect -url tcp:127.0.0.1:3334
targets -set -nocase -filter {name =~ "*A9*#0"}
configparams force-mem-access 1
foreach address {0x43C0000C 0x43C00050 0x43C00060 0x43C0005C} { puts [mrd $address] }
for {set i 0} {$i < 23} {incr i} { puts [format {PROBE[%02d] = 0x%08X} $i [mrd -value [expr {0xFFFF0000 + 4 * $i}]]] }
disconnect
exit
