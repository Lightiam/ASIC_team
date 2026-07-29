// -----------------------------------------------------------------------------
// Neural Compute Engine (NCE)
//
// Original RTL Architect and Digital Designer: Talha Alam
// RTL Implementation and Verification: Talha Alam
// Initial Verified RTL Milestone: 2026
//
// This notice records the original technical authorship of this RTL.
// Ownership and licensing are governed by the written project agreement.
// -----------------------------------------------------------------------------

`timescale 1ns/1ps
`default_nettype none

package nce_pkg;

    parameter int unsigned NCE_LANE_COUNT   = 8;
    parameter int unsigned NCE_LANE_WIDTH   = 32;
    parameter int unsigned NCE_VECTOR_WIDTH =
        NCE_LANE_COUNT * NCE_LANE_WIDTH;

    typedef enum logic [3:0] {
        NCE_OP_NOP      = 4'h0,
        NCE_OP_ADD      = 4'h1,
        NCE_OP_MUL      = 4'h2,
        NCE_OP_MAC      = 4'h3,
        NCE_OP_DOT4_MAC = 4'h4,
        NCE_OP_RELU     = 4'h5,
        NCE_OP_SCALE    = 4'h6
    } nce_opcode_e;

    typedef enum logic [1:0] {
        NCE_PREC_INT8X4 = 2'b00,
        NCE_PREC_BF16X2 = 2'b01,
        NCE_PREC_BF24   = 2'b10,
        NCE_PREC_FP32   = 2'b11
    } nce_precision_e;

    typedef struct packed {
        logic invalid;
        logic overflow;
        logic underflow;
        logic inexact;
        logic saturation;
    } nce_status_t;

    parameter int unsigned NCE_BF16_WIDTH         = 16;
    parameter int unsigned NCE_BF16_EXP_WIDTH     = 8;
    parameter int unsigned NCE_BF16_FRAC_WIDTH    = 7;
    parameter int unsigned NCE_BF16_EXP_BIAS      = 127;

    parameter int unsigned NCE_BF24_WIDTH         = 24;
    parameter int unsigned NCE_BF24_EXP_WIDTH     = 8;
    parameter int unsigned NCE_BF24_FRAC_WIDTH    = 15;
    parameter int unsigned NCE_BF24_EXP_BIAS      = 127;

    parameter int unsigned NCE_FP32_WIDTH         = 32;
    parameter int unsigned NCE_FP32_EXP_WIDTH     = 8;
    parameter int unsigned NCE_FP32_FRAC_WIDTH    = 23;
    parameter int unsigned NCE_FP32_EXP_BIAS      = 127;

endpackage

`default_nettype wire
