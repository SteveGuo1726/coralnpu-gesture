set bit_file "E:/coralnpu_vivado/zynqmini_7z010/coralnpu_lite_cfg9_ps_csr_build/coralnpu_lite_cfg9_ps_csr.bit"

proc cfg9_try_select {pattern} {
  set rc [catch {targets -set -filter "name =~ {$pattern}"} msg]
  puts "CFG9_RECOVER_SELECT {$pattern} rc=$rc msg=$msg"
  return $rc
}

connect
puts "CFG9_RECOVER_TARGETS_BEFORE"
puts [targets]

if {[cfg9_try_select "DAP*"] != 0} {
  cfg9_try_select "xc7z010"
}

set rst_rc [catch {rst -system} rst_msg]
puts "CFG9_RECOVER_RST_SYSTEM rc=$rst_rc msg=$rst_msg"
after 1000

puts "CFG9_RECOVER_TARGETS_AFTER_RST"
puts [targets]

cfg9_try_select "xc7z010"
set fpga_rc [catch {fpga -file $bit_file} fpga_msg]
puts "CFG9_RECOVER_FPGA rc=$fpga_rc msg=$fpga_msg"
after 1500

puts "CFG9_RECOVER_TARGETS_AFTER_FPGA"
puts [targets]
exit
