// ===========================================================================
// nce_regs.h -- NCE AXI4-Lite control/status register map
//
// GENERATED FROM RTL. Do not hand-edit.
//   source : rtl/bus/nce_axi_csr_backend.sv
//   tool   : sw/hal/tools/gen_regs.py
//
// Interface reality, because it is easy to assume otherwise:
//   * AXI4-Lite, 32-bit address. There is no PCIe in this design
//     (docs/spec/ARCHITECTURE.md defers it), so there is no BAR and no
//     fixed physical base. The base is wherever the integrator maps the
//     slave, which is why it is a constructor argument, not a constant.
//   * The entire file spans 0x000..0x138. No paged subsystem windows.
//   * Writes must be 32-bit aligned and use a full byte strobe.
//   * There are no thermal, laser, HBM or ECC registers. Those blocks
//     do not exist in this RTL.
// ===========================================================================

#pragma once

#include <stdint.h>

/* Identity. DEVICE_ID reads ASCII 'NCE0'. */
#define NCE_DEVICE_ID_VALUE   0x4E434530U
#define NCE_VERSION_VALUE     0x00010000U
#define NCE_REG_SPAN_BYTES    0x13CU

/* Offsets in bytes from the slave base. RW = accepted by the write
   decoder; RO = reads back, writes are rejected with an error. */
#define NCE_REG_DEVICE_ID              0x000U   /* RO */
#define NCE_REG_VERSION                0x004U   /* RO */
#define NCE_REG_CONTROL                0x008U   /* RW */
#define NCE_REG_STATUS                 0x00CU   /* RO */
#define NCE_REG_COMMAND                0x010U   /* RW */
#define NCE_REG_COMMAND_COUNT          0x014U   /* RO */
#define NCE_REG_COMMAND_ERROR_COUNT    0x018U   /* RO */
#define NCE_REG_EXECUTE_COUNT          0x01CU   /* RO */
#define NCE_REG_LAST_COMMAND           0x020U   /* RO */
#define NCE_REG_LAST_ERROR             0x024U   /* RO */
#define NCE_REG_VECTOR_CONFIG          0x040U   /* RW */
#define NCE_REG_VECTOR_STAGE_VALID     0x044U   /* RO */
#define NCE_REG_VECTOR_DATA0           0x060U   /* RW */
#define NCE_REG_VECTOR_DATA1           0x064U   /* RW */
#define NCE_REG_VECTOR_DATA2           0x068U   /* RW */
#define NCE_REG_VECTOR_DATA3           0x06CU   /* RW */
#define NCE_REG_VECTOR_DATA4           0x070U   /* RW */
#define NCE_REG_VECTOR_DATA5           0x074U   /* RW */
#define NCE_REG_VECTOR_DATA6           0x078U   /* RW */
#define NCE_REG_VECTOR_DATA7           0x07CU   /* RW */
#define NCE_REG_VECTOR_COMMIT          0x080U   /* RW */
#define NCE_REG_MATRIX_CONFIG          0x0A0U   /* RW */
#define NCE_REG_MATRIX_STAGE_VALID     0x0A4U   /* RO */
#define NCE_REG_MATRIX_DATA0           0x0C0U   /* RW */
#define NCE_REG_MATRIX_DATA1           0x0C4U   /* RW */
#define NCE_REG_MATRIX_DATA2           0x0C8U   /* RW */
#define NCE_REG_MATRIX_DATA3           0x0CCU   /* RW */
#define NCE_REG_MATRIX_DATA4           0x0D0U   /* RW */
#define NCE_REG_MATRIX_DATA5           0x0D4U   /* RW */
#define NCE_REG_MATRIX_DATA6           0x0D8U   /* RW */
#define NCE_REG_MATRIX_DATA7           0x0DCU   /* RW */
#define NCE_REG_MATRIX_COMMIT          0x0E0U   /* RW */
#define NCE_REG_ACCUMULATOR0           0x100U   /* RO */
#define NCE_REG_ACCUMULATOR1           0x104U   /* RO */
#define NCE_REG_ACCUMULATOR2           0x108U   /* RO */
#define NCE_REG_ACCUMULATOR3           0x10CU   /* RO */
#define NCE_REG_ACCUMULATOR4           0x110U   /* RO */
#define NCE_REG_ACCUMULATOR5           0x114U   /* RO */
#define NCE_REG_ACCUMULATOR6           0x118U   /* RO */
#define NCE_REG_ACCUMULATOR7           0x11CU   /* RO */
#define NCE_REG_VECTOR_VALID_MASK      0x120U   /* RO */
#define NCE_REG_MATRIX_VALID_MASK      0x124U   /* RO */
#define NCE_REG_LANE_INVALID           0x128U   /* RO */
#define NCE_REG_LANE_OVERFLOW          0x12CU   /* RO */
#define NCE_REG_LANE_UNDERFLOW         0x130U   /* RO */
#define NCE_REG_LANE_INEXACT           0x134U   /* RO */
#define NCE_REG_GLOBAL_FLAGS           0x138U   /* RO */

/* STATUS (0x00C) bits, from the RTL read path: command handshake and
   IEEE-754 exception flags. */
#define NCE_STATUS_CMD_READY                     (1U << 0)
#define NCE_STATUS_OPERAND_VALID                 (1U << 1)
#define NCE_STATUS_ACCUMULATOR_VALID             (1U << 2)
#define NCE_STATUS_ACCUMULATOR_UPDATE            (1U << 3)
#define NCE_STATUS_INVALID                       (1U << 4)
#define NCE_STATUS_OVERFLOW                      (1U << 5)
#define NCE_STATUS_UNDERFLOW                     (1U << 6)
#define NCE_STATUS_INEXACT                       (1U << 7)
#define NCE_STATUS_LAST_COMMAND_ERROR            (1U << 8)
#define NCE_STATUS_LAST_COMMAND_ERROR_CODE_SHIFT 9U
#define NCE_STATUS_LAST_COMMAND_ERROR_CODE_MASK  0x3U
#define NCE_STATUS_EXECUTE_ISSUE                 (1U << 11)
#define NCE_STATUS_CMD_ACCEPT                    (1U << 12)
