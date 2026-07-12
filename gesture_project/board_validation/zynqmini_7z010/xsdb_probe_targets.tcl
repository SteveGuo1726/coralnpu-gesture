connect
puts "XSDB_TARGETS_BEGIN"
puts [targets]
puts "XSDB_TARGETS_DETAIL_BEGIN"
puts [targets -target-properties]
puts "XSDB_TARGETS_END"
exit
