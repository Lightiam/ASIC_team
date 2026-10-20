// =============================================================================
// nce_hal.hpp -- Layer 19: C++20 hardware abstraction layer for the NCE
//
// Sits directly on the AXI4-Lite CSR map in nce_regs.h, which is generated
// from rtl/bus/nce_axi_csr_backend.sv. Every method here maps onto registers
// the RTL actually decodes.
//
// Scope, stated plainly so callers are not surprised:
//
//   * This design has NO PCIe and NO BAR. ARCHITECTURE.md defers PCIe to a
//     later milestone. The slave base address is therefore supplied by the
//     caller -- from a devicetree node, a UIO mapping, an FPGA bridge window,
//     or a simulation backend. There is no hard-coded physical address.
//
//   * There is no HBM, no laser, no thermal sensor and no ECC in this RTL, so
//     there are no methods for them. Adding such a method would require the
//     corresponding register to exist first.
//
//   * The compute model is: stage 8x32-bit vector operands, stage 8x32-bit
//     matrix operands, commit each, then issue a command and poll STATUS.
//     That is what the hardware implements.
//
// Thread safety: a Device is not synchronised. One owner per instance.
// =============================================================================

#pragma once

#include <array>
#include <cstddef>
#include <cstdint>
#include <expected>
#include <memory>
#include <span>
#include <string_view>

#include "lightrail/nce_regs.h"

namespace lightrail::hal {

// -----------------------------------------------------------------------------
// Errors. Every fallible operation returns std::expected rather than throwing
// or returning a bare bool, so a caller cannot ignore a failure by accident.
// -----------------------------------------------------------------------------
enum class Error {
    MapFailed,          // the backend could not map the register window
    NotMapped,          // operation attempted before a successful map
    BadAlignment,       // offset not 32-bit aligned
    OutOfRange,         // offset outside NCE_REG_SPAN_BYTES
    IdentityMismatch,   // DEVICE_ID did not read back "NCE0"
    VersionMismatch,    // VERSION did not match what this HAL was built for
    Timeout,            // command did not complete within the deadline
    CommandError,       // hardware reported an error for the issued command
};

std::string_view to_string(Error e) noexcept;

// -----------------------------------------------------------------------------
// Register access backend.
//
// The HAL does not assume how the registers are reached. A real system
// supplies an mmap-backed implementation; a test or co-simulation supplies one
// that talks to a simulator. This is what makes the HAL testable without
// hardware, and it is why there is no /dev/mem in this header.
// -----------------------------------------------------------------------------
class RegisterBackend {
public:
    virtual ~RegisterBackend() = default;
    virtual uint32_t read32(uint32_t offset) const noexcept = 0;
    virtual void     write32(uint32_t offset, uint32_t value) noexcept = 0;
};

// Backend over a caller-provided virtual address (mmap, UIO, FPGA bridge).
class MmioBackend final : public RegisterBackend {
public:
    explicit MmioBackend(volatile uint32_t* base) noexcept : base_(base) {}
    uint32_t read32(uint32_t offset) const noexcept override;
    void     write32(uint32_t offset, uint32_t value) noexcept override;
private:
    volatile uint32_t* base_;
};

// -----------------------------------------------------------------------------
// Decoded STATUS word. Mirrors the RTL read path exactly.
// -----------------------------------------------------------------------------
struct Status {
    bool     cmd_ready;
    bool     operand_valid;
    bool     accumulator_valid;
    bool     accumulator_update;
    bool     invalid;            // IEEE-754 invalid operation
    bool     overflow;
    bool     underflow;
    bool     inexact;
    bool     last_command_error;
    uint8_t  last_command_error_code;   // 2 bits
    bool     execute_issue;
    bool     cmd_accept;

    [[nodiscard]] bool any_fp_exception() const noexcept {
        return invalid || overflow || underflow || inexact;
    }
};

// Per-lane IEEE-754 exception masks, one bit per SIMD lane.
struct LaneFlags {
    uint32_t invalid;
    uint32_t overflow;
    uint32_t underflow;
    uint32_t inexact;
};

// -----------------------------------------------------------------------------
// The device.
// -----------------------------------------------------------------------------
class Device {
public:
    // Takes ownership of the backend. Does not touch hardware; call probe().
    explicit Device(std::unique_ptr<RegisterBackend> backend) noexcept;

    Device(const Device&)            = delete;
    Device& operator=(const Device&) = delete;
    Device(Device&&) noexcept;
    Device& operator=(Device&&) noexcept;
    ~Device();

    // Reads DEVICE_ID and VERSION and checks them. Call before anything else.
    [[nodiscard]] std::expected<void, Error> probe() const noexcept;

    [[nodiscard]] uint32_t device_id() const noexcept;
    [[nodiscard]] uint32_t version()   const noexcept;
    [[nodiscard]] Status   status()    const noexcept;

    // CONTROL is the only general-purpose writable control register.
    void     write_control(uint32_t value) noexcept;
    [[nodiscard]] uint32_t read_control() const noexcept;

    // ---- operand staging ----------------------------------------------------
    // Stage the eight 32-bit words of a vector or matrix operand, then commit.
    // The RTL requires a full 32-bit write; partial strobes are rejected.
    [[nodiscard]] std::expected<void, Error>
        stage_vector(std::span<const uint32_t, 8> words) noexcept;

    [[nodiscard]] std::expected<void, Error>
        stage_matrix(std::span<const uint32_t, 8> words) noexcept;

    void write_vector_config(uint32_t cfg) noexcept;
    void write_matrix_config(uint32_t cfg) noexcept;

    // Commit requires bit 0 set and all eight words staged, per the RTL.
    [[nodiscard]] std::expected<void, Error> commit_vector() noexcept;
    [[nodiscard]] std::expected<void, Error> commit_matrix() noexcept;

    // ---- command issue ------------------------------------------------------
    // Writes COMMAND, then polls STATUS until the command retires or the
    // deadline expires. Returns CommandError if the hardware flagged one.
    [[nodiscard]] std::expected<void, Error>
        issue_command(uint32_t command, uint32_t poll_limit = 10000) noexcept;

    // ---- results ------------------------------------------------------------
    [[nodiscard]] std::array<uint32_t, 8> read_accumulators() const noexcept;
    [[nodiscard]] LaneFlags               read_lane_flags()   const noexcept;
    [[nodiscard]] uint32_t                read_global_flags() const noexcept;

    // ---- counters -----------------------------------------------------------
    [[nodiscard]] uint32_t command_count()       const noexcept;
    [[nodiscard]] uint32_t command_error_count() const noexcept;
    [[nodiscard]] uint32_t execute_count()       const noexcept;
    [[nodiscard]] uint32_t last_command()        const noexcept;
    [[nodiscard]] uint32_t last_error()          const noexcept;

    // ---- raw access, bounds- and alignment-checked ---------------------------
    [[nodiscard]] std::expected<uint32_t, Error> read_raw(uint32_t offset) const noexcept;
    [[nodiscard]] std::expected<void, Error>     write_raw(uint32_t offset,
                                                           uint32_t value) noexcept;

private:
    std::unique_ptr<RegisterBackend> backend_;

    [[nodiscard]] static std::expected<void, Error> check_offset(uint32_t off) noexcept;
};

}  // namespace lightrail::hal
