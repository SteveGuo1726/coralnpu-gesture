set report_root "//wsl.localhost/Ubuntu-22.04/home/steveguo/coralnpu-gesture/gesture_project/board_validation/zynqmini_7z010/reports"
file mkdir $report_root

set patterns {
  *xc7z010*
  *7z010*
  *xc7z*
  *zynq*
}

set fp [open "$report_root/vivado_available_parts_probe.txt" "w"]
foreach pattern $patterns {
  puts $fp "PATTERN $pattern"
  set parts [get_parts -quiet $pattern]
  if {[llength $parts] == 0} {
    puts $fp "  <none>"
  } else {
    foreach p $parts {
      puts $fp "  $p"
    }
  }
}
close $fp

puts "PART_PROBE_DONE"
