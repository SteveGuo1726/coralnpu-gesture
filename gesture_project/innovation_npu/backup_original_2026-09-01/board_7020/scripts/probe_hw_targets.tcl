# PROJECT_LOCAL_SELF_RESEARCH_NOT_GOOGLE_OFFICIAL
# Read-only hardware probe: connect to hw_server and list JTAG targets.
# This is the first step of the board-flow audit; it changes no device state.
set url "tcp:127.0.0.1:3121"
if {[info exists ::env(GESTUREFLOW_HW_SERVER_URL)] && $::env(GESTUREFLOW_HW_SERVER_URL) ne ""} {
  set url $::env(GESTUREFLOW_HW_SERVER_URL)
}
puts "GESTUREFLOW_HW_PROBE_URL = $url"
if {[catch {connect -url $url} err]} {
  puts "GESTUREFLOW_HW_PROBE_CONNECT_FAILED = $err"
  exit 2
}
puts "GESTUREFLOW_HW_PROBE_TARGETS_BEGIN"
puts [targets]
puts "GESTUREFLOW_HW_PROBE_TARGETS_END"
disconnect
exit 0
