set report_root "//wsl.localhost/Ubuntu-22.04/home/steveguo/coralnpu-gesture/gesture_project/board_validation/zynqmini_7z010/reports"
file mkdir $report_root

set patterns {
  *xc7a*
  *xc7k*
  *xc7s*
  *xcku*
  *xcvu*
  *xczu*
  *xck26*
  *xcve*
}

set fp [open "$report_root/vivado_installed_family_probe.txt" "w"]
foreach pattern $patterns {
  set parts [get_parts -quiet $pattern]
  puts $fp "PATTERN $pattern COUNT [llength $parts]"
  set limit 20
  set idx 0
  foreach p $parts {
    if {$idx >= $limit} {
      puts $fp "  ..."
      break
    }
    puts $fp "  $p"
    incr idx
  }
}
close $fp

puts "INSTALLED_FAMILY_PROBE_DONE"
