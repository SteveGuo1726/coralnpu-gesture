# PROJECT_LOCAL_SELF_RESEARCH_NOT_GOOGLE_OFFICIAL
# Windows-local XSCT diagnostic. This intentionally exercises only the TCF
# client so board application state cannot be changed while connection fails.
puts "GESTUREFLOW_XSCT_TCF_DIAGNOSTIC_BEGIN"
puts [format {XSCT_VERSION = %s} [version]]
puts [format {TCL_PLATFORM_OS = %s} $::tcl_platform(os)]
puts [format {TCL_PLATFORM_MACHINE = %s} $::tcl_platform(machine)]
puts [format {ENV_XILINX_VITIS = %s} [expr {[info exists ::env(XILINX_VITIS)] ? $::env(XILINX_VITIS) : "<unset>"}]]
puts [format {ENV_XILINX_VIVADO = %s} [expr {[info exists ::env(XILINX_VIVADO)] ? $::env(XILINX_VIVADO) : "<unset>"}]]
puts [format {TCF_CONNECT_COMMAND = %s} [info commands ::tcf::connect]]

set url "tcp:127.0.0.1:3334"
set rc [catch {connect -url $url} message options]
puts [format {TCF_CONNECT_RC = %d} $rc]
puts [format {TCF_CONNECT_MESSAGE = %s} $message]
if {$rc != 0} {
  puts [format {TCF_CONNECT_ERRORCODE = %s} [dict get $options -errorcode]]
  puts "TCF_CONNECT_ERRORINFO_BEGIN"
  puts [dict get $options -errorinfo]
  puts "TCF_CONNECT_ERRORINFO_END"
  exit 1
}
puts "GESTUREFLOW_XSCT_TCF_CONNECT_PASS"
disconnect
exit 0
