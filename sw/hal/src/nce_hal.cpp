// =============================================================================
// nce_hal.cpp -- Layer 19 HAL implementation
// =============================================================================

#include "lightrail/nce_hal.hpp"

#include <atomic>

namespace lightrail::hal {

std::string_view to_string(Error e) noexcept {
    switch (e) {
        case Error::MapFailed:        return "MapFailed";
        case Error::NotMapped:        return "NotMapped";
        case Error::BadAlignment:     return "BadAlignment";
        case Error::OutOfRange:       return "OutOfRange";
        case Error::IdentityMismatch: return "IdentityMismatch";
        case Error::VersionMismatch:  return "VersionMismatch";
        case Error::Timeout:          return "Timeout";
        case Error::CommandError:     return "CommandError";
    }
    return "Unknown";
}

// -----------------------------------------------------------------------------
// MmioBackend
//
// The compiler must not reorder, merge or elide register accesses. `volatile`
// prevents elision and merging; the fences stop the compiler moving unrelated
// accesses across a register operation. On a weakly ordered CPU the fences are
// what keep a staged operand from being observed after its commit.
// -----------------------------------------------------------------------------
uint32_t MmioBackend::read32(uint32_t offset) const noexcept {
    std::atomic_signal_fence(std::memory_order_acquire);
    const uint32_t v = base_[offset / sizeof(uint32_t)];
    std::atomic_thread_fence(std::memory_order_acquire);
    return v;
}

void MmioBackend::write32(uint32_t offset, uint32_t value) noexcept {
    std::atomic_thread_fence(std::memory_order_release);
    base_[offset / sizeof(uint32_t)] = value;
    std::atomic_signal_fence(std::memory_order_release);
}

// -----------------------------------------------------------------------------
// Device
// -----------------------------------------------------------------------------
Device::Device(std::unique_ptr<RegisterBackend> backend) noexcept
    : backend_(std::move(backend)) {}

Device::Device(Device&&) noexcept            = default;
Device& Device::operator=(Device&&) noexcept = default;
Device::~Device()                            = default;

std::expected<void, Error> Device::check_offset(uint32_t off) noexcept {
    if ((off & 0x3U) != 0U)          return std::unexpected(Error::BadAlignment);
    if (off >= NCE_REG_SPAN_BYTES)   return std::unexpected(Error::OutOfRange);
    return {};
}

std::expected<void, Error> Device::probe() const noexcept {
    if (!backend_) return std::unexpected(Error::NotMapped);

    if (backend_->read32(NCE_REG_DEVICE_ID) != NCE_DEVICE_ID_VALUE)
        return std::unexpected(Error::IdentityMismatch);

    // Major version must match; the RTL encodes it in the upper half.
    const uint32_t v = backend_->read32(NCE_REG_VERSION);
    if ((v & 0xFFFF0000U) != (NCE_VERSION_VALUE & 0xFFFF0000U))
        return std::unexpected(Error::VersionMismatch);

    return {};
}

uint32_t Device::device_id() const noexcept {
    return backend_ ? backend_->read32(NCE_REG_DEVICE_ID) : 0U;
}

uint32_t Device::version() const noexcept {
    return backend_ ? backend_->read32(NCE_REG_VERSION) : 0U;
}

Status Device::status() const noexcept {
    Status s{};
    if (!backend_) return s;

    const uint32_t r = backend_->read32(NCE_REG_STATUS);
    s.cmd_ready               = (r & NCE_STATUS_CMD_READY) != 0U;
    s.operand_valid           = (r & NCE_STATUS_OPERAND_VALID) != 0U;
    s.accumulator_valid       = (r & NCE_STATUS_ACCUMULATOR_VALID) != 0U;
    s.accumulator_update      = (r & NCE_STATUS_ACCUMULATOR_UPDATE) != 0U;
    s.invalid                 = (r & NCE_STATUS_INVALID) != 0U;
    s.overflow                = (r & NCE_STATUS_OVERFLOW) != 0U;
    s.underflow               = (r & NCE_STATUS_UNDERFLOW) != 0U;
    s.inexact                 = (r & NCE_STATUS_INEXACT) != 0U;
    s.last_command_error      = (r & NCE_STATUS_LAST_COMMAND_ERROR) != 0U;
    s.last_command_error_code =
        static_cast<uint8_t>((r >> NCE_STATUS_LAST_COMMAND_ERROR_CODE_SHIFT)
                             & NCE_STATUS_LAST_COMMAND_ERROR_CODE_MASK);
    s.execute_issue           = (r & NCE_STATUS_EXECUTE_ISSUE) != 0U;
    s.cmd_accept              = (r & NCE_STATUS_CMD_ACCEPT) != 0U;
    return s;
}

void Device::write_control(uint32_t value) noexcept {
    if (backend_) backend_->write32(NCE_REG_CONTROL, value);
}

uint32_t Device::read_control() const noexcept {
    return backend_ ? backend_->read32(NCE_REG_CONTROL) : 0U;
}

void Device::write_vector_config(uint32_t cfg) noexcept {
    if (backend_) backend_->write32(NCE_REG_VECTOR_CONFIG, cfg);
}

void Device::write_matrix_config(uint32_t cfg) noexcept {
    if (backend_) backend_->write32(NCE_REG_MATRIX_CONFIG, cfg);
}

std::expected<void, Error>
Device::stage_vector(std::span<const uint32_t, 8> words) noexcept {
    if (!backend_) return std::unexpected(Error::NotMapped);
    // VECTOR_DATA0..7 are contiguous, 4 bytes apart.
    for (uint32_t i = 0; i < 8U; ++i)
        backend_->write32(NCE_REG_VECTOR_DATA0 + i * 4U, words[i]);
    return {};
}

std::expected<void, Error>
Device::stage_matrix(std::span<const uint32_t, 8> words) noexcept {
    if (!backend_) return std::unexpected(Error::NotMapped);
    for (uint32_t i = 0; i < 8U; ++i)
        backend_->write32(NCE_REG_MATRIX_DATA0 + i * 4U, words[i]);
    return {};
}

std::expected<void, Error> Device::commit_vector() noexcept {
    if (!backend_) return std::unexpected(Error::NotMapped);
    // The RTL rejects a commit unless bit 0 is set and all words are staged.
    backend_->write32(NCE_REG_VECTOR_COMMIT, 1U);
    if (backend_->read32(NCE_REG_VECTOR_STAGE_VALID) != 0xFFU)
        return std::unexpected(Error::CommandError);
    return {};
}

std::expected<void, Error> Device::commit_matrix() noexcept {
    if (!backend_) return std::unexpected(Error::NotMapped);
    backend_->write32(NCE_REG_MATRIX_COMMIT, 1U);
    if (backend_->read32(NCE_REG_MATRIX_STAGE_VALID) != 0xFFU)
        return std::unexpected(Error::CommandError);
    return {};
}

std::expected<void, Error>
Device::issue_command(uint32_t command, uint32_t poll_limit) noexcept {
    if (!backend_) return std::unexpected(Error::NotMapped);

    // Wait for the command port to be free before writing it.
    uint32_t spins = 0;
    while (!status().cmd_ready) {
        if (++spins >= poll_limit) return std::unexpected(Error::Timeout);
    }

    const uint32_t errors_before = command_error_count();
    backend_->write32(NCE_REG_COMMAND, command);

    // Retire when the pipeline reports ready again.
    spins = 0;
    for (;;) {
        const Status s = status();
        if (s.last_command_error) return std::unexpected(Error::CommandError);
        if (s.cmd_ready) break;
        if (++spins >= poll_limit) return std::unexpected(Error::Timeout);
    }

    // A command can be rejected without latching last_command_error, so the
    // error counter is checked as well rather than trusting one flag.
    if (command_error_count() != errors_before)
        return std::unexpected(Error::CommandError);

    return {};
}

std::array<uint32_t, 8> Device::read_accumulators() const noexcept {
    std::array<uint32_t, 8> acc{};
    if (!backend_) return acc;
    for (uint32_t i = 0; i < 8U; ++i)
        acc[i] = backend_->read32(NCE_REG_ACCUMULATOR0 + i * 4U);
    return acc;
}

LaneFlags Device::read_lane_flags() const noexcept {
    LaneFlags f{};
    if (!backend_) return f;
    f.invalid   = backend_->read32(NCE_REG_LANE_INVALID);
    f.overflow  = backend_->read32(NCE_REG_LANE_OVERFLOW);
    f.underflow = backend_->read32(NCE_REG_LANE_UNDERFLOW);
    f.inexact   = backend_->read32(NCE_REG_LANE_INEXACT);
    return f;
}

uint32_t Device::read_global_flags() const noexcept {
    return backend_ ? backend_->read32(NCE_REG_GLOBAL_FLAGS) : 0U;
}

uint32_t Device::command_count() const noexcept {
    return backend_ ? backend_->read32(NCE_REG_COMMAND_COUNT) : 0U;
}
uint32_t Device::command_error_count() const noexcept {
    return backend_ ? backend_->read32(NCE_REG_COMMAND_ERROR_COUNT) : 0U;
}
uint32_t Device::execute_count() const noexcept {
    return backend_ ? backend_->read32(NCE_REG_EXECUTE_COUNT) : 0U;
}
uint32_t Device::last_command() const noexcept {
    return backend_ ? backend_->read32(NCE_REG_LAST_COMMAND) : 0U;
}
uint32_t Device::last_error() const noexcept {
    return backend_ ? backend_->read32(NCE_REG_LAST_ERROR) : 0U;
}

std::expected<uint32_t, Error> Device::read_raw(uint32_t offset) const noexcept {
    if (!backend_) return std::unexpected(Error::NotMapped);
    if (auto ok = check_offset(offset); !ok) return std::unexpected(ok.error());
    return backend_->read32(offset);
}

std::expected<void, Error> Device::write_raw(uint32_t offset,
                                             uint32_t value) noexcept {
    if (!backend_) return std::unexpected(Error::NotMapped);
    if (auto ok = check_offset(offset); !ok) return std::unexpected(ok.error());
    backend_->write32(offset, value);
    return {};
}

}  // namespace lightrail::hal
