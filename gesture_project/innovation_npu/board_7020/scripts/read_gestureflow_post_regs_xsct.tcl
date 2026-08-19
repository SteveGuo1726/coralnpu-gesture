# PROJECT_LOCAL_SELF_RESEARCH_NOT_GOOGLE_OFFICIAL
# Non-destructive postprocess register readback after a GestureFlow board run.
proc select_target_with_recovery {filter description} {
  if {[catch {targets -set -nocase -filter $filter}]} {
    error "failed to select $description with filter '$filter'"
  }
}
connect -url tcp:127.0.0.1:3334
select_target_with_recovery {name =~ "APU*"} {APU target}
configparams force-mem-access 1
foreach {name address} {
  LAYER_MODE 0x43c00064
  DMA_SOURCE 0x43c00044
  DMA_BYTES 0x43c00048
  POST_GAP_MULT 0x43c00080
  POST_GAP_SHIFT 0x43c00084
  POST_QCFG 0x43c00088
  POST_GAP_FNV 0x43c0008c
  POST_FC_FNV 0x43c00090
  POST_CLASS 0x43c00094
  POST_CYCLES 0x43c00098
  POST_PROGRESS 0x43c0009c
  POST_DEBUG_GAP_SUM0 0x43c000a0
  POST_DEBUG_GAP_SUM6 0x43c000a4
  DMA_STATUS 0x43c00050
} {
  puts [format {%s = 0x%08X} $name [mrd -value $address]]
}
puts {HEAD_DDR_FIRST_112_BYTES}
for {set offset 0} {$offset < 112} {incr offset 4} {
  set address [expr {0x001e00c0 + $offset}]
  puts [format {0x%08X = 0x%08X} $address [mrd -value $address]]
}
disconnect
exit
