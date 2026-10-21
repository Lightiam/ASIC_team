// =============================================================================
// nce_emulator.cpp
// =============================================================================

#include "nce_emulator.hpp"

#include <cstdlib>
#include <cstring>

namespace lightrail::emu {

bool emulation_enabled() noexcept {
    const char* v = std::getenv("LIGHTRAIL_EMULATE");
    return v != nullptr && v[0] == '1' && v[1] == '\0';
}

// -----------------------------------------------------------------------------
// EmulatedDevice
// -----------------------------------------------------------------------------
EmulatedDevice::EmulatedDevice() {
    regs_[NCE_REG_DEVICE_ID] = kEmuDeviceId;
    regs_[NCE_REG_VERSION]   = NCE_VERSION_VALUE;
    regs_[NCE_REG_STATUS]    = NCE_STATUS_CMD_READY;
}

uint32_t EmulatedDevice::get(uint32_t off) const noexcept {
    auto it = regs_.find(off);
    return it == regs_.end() ? 0u : it->second;
}

void EmulatedDevice::set(uint32_t off, uint32_t v) noexcept {
    regs_[off] = v;
}

uint32_t EmulatedDevice::read32(uint32_t offset) const noexcept {
    std::lock_guard<std::mutex> lock(mu_);
    if (offset == NCE_REG_VECTOR_STAGE_VALID) return vector_valid_;
    if (offset == NCE_REG_MATRIX_STAGE_VALID) return matrix_valid_;
    return get(offset);
}

void EmulatedDevice::write32(uint32_t offset, uint32_t value) noexcept {
    std::lock_guard<std::mutex> lock(mu_);

    // Read-only registers drop writes, as the RTL's decoder does.
    if (offset == NCE_REG_DEVICE_ID || offset == NCE_REG_VERSION ||
        offset == NCE_REG_STATUS) {
        return;
    }

    if (offset >= NCE_REG_VECTOR_DATA0 && offset <= NCE_REG_VECTOR_DATA7) {
        const uint32_t i = (offset - NCE_REG_VECTOR_DATA0) / 4u;
        vector_stage_[i] = value;
        vector_valid_ |= (1u << i);
        set(offset, value);
        return;
    }
    if (offset >= NCE_REG_MATRIX_DATA0 && offset <= NCE_REG_MATRIX_DATA7) {
        const uint32_t i = (offset - NCE_REG_MATRIX_DATA0) / 4u;
        matrix_stage_[i] = value;
        matrix_valid_ |= (1u << i);
        set(offset, value);
        return;
    }

    if (offset == NCE_REG_VECTOR_COMMIT) {
        if ((value & 1u) == 0u || vector_valid_ != 0xFFu) {
            set(NCE_REG_COMMAND_ERROR_COUNT, get(NCE_REG_COMMAND_ERROR_COUNT) + 1);
        }
        set(offset, value);
        return;
    }
    if (offset == NCE_REG_MATRIX_COMMIT) {
        if ((value & 1u) == 0u || matrix_valid_ != 0xFFu) {
            set(NCE_REG_COMMAND_ERROR_COUNT, get(NCE_REG_COMMAND_ERROR_COUNT) + 1);
        }
        set(offset, value);
        return;
    }

    if (offset == NCE_REG_COMMAND) {
        set(NCE_REG_COMMAND_COUNT, get(NCE_REG_COMMAND_COUNT) + 1);
        set(NCE_REG_LAST_COMMAND, value);
        execute(value);
        set(NCE_REG_STATUS, get(NCE_REG_STATUS) | NCE_STATUS_CMD_READY);
        return;
    }

    set(offset, value);
}

void EmulatedDevice::execute(uint32_t command) noexcept {
    // Command 1: elementwise multiply-accumulate of the two staged operands
    // into the accumulators. Enough to exercise the full staging -> commit ->
    // execute -> readback path that the HAL and daemon drive.
    if (command == 1u) {
        if (vector_valid_ != 0xFFu || matrix_valid_ != 0xFFu) {
            set(NCE_REG_COMMAND_ERROR_COUNT, get(NCE_REG_COMMAND_ERROR_COUNT) + 1);
            return;
        }
        for (uint32_t i = 0; i < 8u; ++i) {
            const int32_t a = static_cast<int32_t>(vector_stage_[i]);
            const int32_t b = static_cast<int32_t>(matrix_stage_[i]);
            const uint32_t off = NCE_REG_ACCUMULATOR0 + i * 4u;
            set(off, static_cast<uint32_t>(static_cast<int32_t>(get(off)) + a * b));
        }
        ++exec_count_;
        set(NCE_REG_EXECUTE_COUNT, exec_count_);
        vector_valid_ = 0;
        matrix_valid_ = 0;
        return;
    }

    // Command 2: clear accumulators.
    if (command == 2u) {
        for (uint32_t i = 0; i < 8u; ++i) set(NCE_REG_ACCUMULATOR0 + i * 4u, 0u);
        ++exec_count_;
        set(NCE_REG_EXECUTE_COUNT, exec_count_);
        return;
    }

    // Anything else is rejected rather than silently ignored.
    set(NCE_REG_COMMAND_ERROR_COUNT, get(NCE_REG_COMMAND_ERROR_COUNT) + 1);
}

std::array<uint32_t, 8> EmulatedDevice::accumulators() const noexcept {
    std::lock_guard<std::mutex> lock(mu_);
    std::array<uint32_t, 8> out{};
    for (uint32_t i = 0; i < 8u; ++i) out[i] = get(NCE_REG_ACCUMULATOR0 + i * 4u);
    return out;
}

// -----------------------------------------------------------------------------
// Endpoint
// -----------------------------------------------------------------------------
std::pair<std::shared_ptr<Endpoint>, std::shared_ptr<Endpoint>> Endpoint::pair() {
    auto mu = std::make_shared<std::mutex>();
    auto q_a = std::make_shared<std::deque<Message>>();   // messages toward A
    auto q_b = std::make_shared<std::deque<Message>>();   // messages toward B

    auto a = std::shared_ptr<Endpoint>(new Endpoint());
    auto b = std::shared_ptr<Endpoint>(new Endpoint());

    a->mu_ = mu; a->inbox_ = q_a; a->outbox_ = q_b;
    b->mu_ = mu; b->inbox_ = q_b; b->outbox_ = q_a;
    return {a, b};
}

bool Endpoint::send(const void* data, size_t bytes, int tag) noexcept {
    if (data == nullptr && bytes != 0) return false;
    std::lock_guard<std::mutex> lock(*mu_);
    Message m;
    m.tag = tag;
    m.bytes.resize(bytes);
    if (bytes) std::memcpy(m.bytes.data(), data, bytes);
    outbox_->push_back(std::move(m));
    sent_ += bytes;
    return true;
}

bool Endpoint::try_recv(void* data, size_t bytes, int tag) noexcept {
    std::lock_guard<std::mutex> lock(*mu_);
    for (auto it = inbox_->begin(); it != inbox_->end(); ++it) {
        if (it->tag != tag) continue;
        // Size must match: a short read would silently truncate a tensor.
        if (it->bytes.size() != bytes) return false;
        if (bytes) std::memcpy(data, it->bytes.data(), bytes);
        received_ += bytes;
        inbox_->erase(it);
        return true;
    }
    return false;
}

}  // namespace lightrail::emu
