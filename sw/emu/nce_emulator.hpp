// =============================================================================
// nce_emulator.hpp -- software model of the NCE device and a real transport
//
// WHY THIS EXISTS
// ---------------
// Everything above the HAL (Layers 13-22) was algorithms with nothing
// underneath, because there is no silicon and no driver. This supplies a
// device the stack can actually run against: a register model that behaves
// like rtl/bus/nce_axi_csr_backend.sv, and a transport that genuinely copies
// bytes between ranks.
//
// It is an EMULATOR. It is not hardware and must never be mistaken for it:
//
//   * Activation is opt-in via the environment variable LIGHTRAIL_EMULATE=1.
//     Nothing selects it implicitly, so a production run on a machine with
//     no device fails rather than silently computing in software.
//   * The device identifies itself with a distinct id, EMU0 rather than
//     NCE0, so any log or dataroom artefact produced against it is
//     self-evidently emulated.
//   * Timing is not modelled. Throughput numbers from this are meaningless
//     as hardware performance; what it validates is correctness and
//     protocol, which is the part that is hard to get right later.
//
// The register behaviour mirrors the RTL: writes to read-only addresses are
// dropped, staging a data word sets its STAGE_VALID bit, and a commit is
// rejected unless all eight words are staged.
// =============================================================================

#pragma once

#include <array>
#include <cstdint>
#include <deque>
#include <map>
#include <memory>
#include <mutex>
#include <string>
#include <vector>

#include "lightrail/nce_hal.hpp"

namespace lightrail::emu {

// Distinct from the RTL's "NCE0" so emulated runs are identifiable.
inline constexpr uint32_t kEmuDeviceId = 0x454D5530u;   // "EMU0"

// -----------------------------------------------------------------------------
// Register model
// -----------------------------------------------------------------------------
class EmulatedDevice final : public hal::RegisterBackend {
public:
    EmulatedDevice();

    uint32_t read32(uint32_t offset) const noexcept override;
    void     write32(uint32_t offset, uint32_t value) noexcept override;

    // Execute whatever the staged operands describe. Called when a command
    // is written; exposed for tests.
    void execute(uint32_t command) noexcept;

    [[nodiscard]] std::array<uint32_t, 8> accumulators() const noexcept;
    [[nodiscard]] uint32_t commands_executed() const noexcept { return exec_count_; }

private:
    mutable std::mutex              mu_;
    mutable std::map<uint32_t, uint32_t> regs_;
    std::array<uint32_t, 8>         vector_stage_{};
    std::array<uint32_t, 8>         matrix_stage_{};
    uint32_t                        vector_valid_{0};
    uint32_t                        matrix_valid_{0};
    uint32_t                        exec_count_{0};

    uint32_t get(uint32_t off) const noexcept;
    void     set(uint32_t off, uint32_t v) noexcept;
};

// -----------------------------------------------------------------------------
// Transport
//
// A real transport: bytes written by one endpoint are readable by its peer.
// In-process queues, so this exercises the full send/recv/completion protocol
// without a network. A cross-host version would replace the queue with a
// socket or shared-memory segment; the interface is what matters here.
// -----------------------------------------------------------------------------
class Endpoint {
public:
    struct Message {
        int                  tag;
        std::vector<uint8_t> bytes;
    };

    // Returns the two ends of a connected pair.
    static std::pair<std::shared_ptr<Endpoint>, std::shared_ptr<Endpoint>> pair();

    bool send(const void* data, size_t bytes, int tag) noexcept;
    // Non-blocking: false when nothing matching has arrived yet.
    bool try_recv(void* data, size_t bytes, int tag) noexcept;

    [[nodiscard]] size_t bytes_sent() const noexcept { return sent_; }
    [[nodiscard]] size_t bytes_received() const noexcept { return received_; }

private:
    std::shared_ptr<std::mutex>            mu_;
    std::shared_ptr<std::deque<Message>>   inbox_;     // this end reads here
    std::shared_ptr<std::deque<Message>>   outbox_;    // this end writes here
    size_t sent_{0};
    size_t received_{0};
};

// True only when LIGHTRAIL_EMULATE=1 is set in the environment.
[[nodiscard]] bool emulation_enabled() noexcept;

}  // namespace lightrail::emu
