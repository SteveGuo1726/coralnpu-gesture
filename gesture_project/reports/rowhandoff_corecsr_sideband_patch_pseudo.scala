// rowhandoff sideband CSR pseudo patch for CoreAxiCSR.scala
// 目标：沿用官方 CoreCSR 的 allReadRegs/groupedRegs 结构，
// 增加一组只读 board trace/counter CSR，不修改 scalar csr.out。

package coralnpu

import chisel3._
import chisel3.util._

class RowhandoffCsrIO extends Bundle {
  val rowhandoff_hit_count = Input(UInt(16.W))
  val rowhandoff_miss_count = Input(UInt(16.W))
  val rowhandoff_invalidate_count = Input(UInt(16.W))
  val rowhandoff_produce_count = Input(UInt(16.W))
  val rowhandoff_tail_hit_count = Input(UInt(16.W))
  val interior_row_enter_count = Input(UInt(16.W))
  val right_edge_done_count = Input(UInt(16.W))
  val rowhandoff_row_out_y_last = Input(UInt(6.W))
}

object RowhandoffCsrAddrs {
  val rowhandoff_hit_count = 0x820.U
  val rowhandoff_miss_count = 0x824.U
  val rowhandoff_invalidate_count = 0x828.U
  val rowhandoff_produce_count = 0x82c.U
  val rowhandoff_tail_hit_count = 0x830.U
  val interior_row_enter_count = 0x834.U
  val right_edge_done_count = 0x838.U
  val rowhandoff_row_out_y_last = 0x83c.U
}

// In CoreCSR IO bundle, add:
// val rowhandoff = Input(new RowhandoffCsrIO)

// In CoreCSR read map section, add:
val rowhandoffReadMap = Seq(
  RowhandoffCsrAddrs.rowhandoff_hit_count -> io.rowhandoff.rowhandoff_hit_count,
  RowhandoffCsrAddrs.rowhandoff_miss_count -> io.rowhandoff.rowhandoff_miss_count,
  RowhandoffCsrAddrs.rowhandoff_invalidate_count -> io.rowhandoff.rowhandoff_invalidate_count,
  RowhandoffCsrAddrs.rowhandoff_produce_count -> io.rowhandoff.rowhandoff_produce_count,
  RowhandoffCsrAddrs.rowhandoff_tail_hit_count -> io.rowhandoff.rowhandoff_tail_hit_count,
  RowhandoffCsrAddrs.interior_row_enter_count -> io.rowhandoff.interior_row_enter_count,
  RowhandoffCsrAddrs.right_edge_done_count -> io.rowhandoff.right_edge_done_count,
  RowhandoffCsrAddrs.rowhandoff_row_out_y_last -> io.rowhandoff.rowhandoff_row_out_y_last
).map { case (k, v) => k.litValue.toInt -> v }.toMap

// Then replace:
// val allReadRegs = coreRegMap ++ csrRegMap ++ debugReadMap
// with:
// val allReadRegs = coreRegMap ++ csrRegMap ++ debugReadMap ++ rowhandoffReadMap

// Write map intentionally unchanged in trace-only first stage:
// val allWriteRegs = Map(0x0 -> true.B, 0x4 -> true.B) ++ debugWriteValidMap

// In CoreAxiCSR IO bundle, add:
// val rowhandoff = Input(new RowhandoffCsrIO)

// In CoreAxiCSR module body, add:
// csr.io.rowhandoff := io.rowhandoff

// In CoreAxi top-level, connect these from the future rowhandoff counter bank.
