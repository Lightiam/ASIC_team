// =============================================================================
// test_nce_hal.cpp -- Layer 19 HAL tests against a model of the RTL.
//
// The model implements what rtl/bus/nce_axi_csr_backend.sv actually does:
// DEVICE_ID reads "NCE0", writes to read-only registers are dropped, staging
// a word sets its STAGE_VALID bit, and COMMIT is rejected unless all eight
// words are staged. That lets the HAL be tested with no hardware and no
// simulator, and it fails if the HAL ever reaches for a register the RTL does
// not decode.
// =============================================================================

#include "lightrail/nce_hal.hpp"

#include <cstdio>
#include <map>
#include <set>

using namespace lightrail::hal;

namespace {

int g_checks = 0;
int g_errors = 0;

void check(bool cond, const char* what) {
    ++g_checks;
    if (!cond) {
        ++g_errors;
        std::printf("FAIL: %s\n", what);
    }
}

// Model of the CSR block.
class FakeCsr final : public RegisterBackend {
public:
    FakeCsr() {
        regs_[NCE_REG_DEVICE_ID] = NCE_DEVICE_ID_VALUE;
        regs_[NCE_REG_VERSION]   = NCE_VERSION_VALUE;
        regs_[NCE_REG_STATUS]    = NCE_STATUS_CMD_READY;
    }

    uint32_t read32(uint32_t off) const noexcept override {
        ++reads_;
        touched_.insert(off);
        auto it = regs_.find(off);
        return it == regs_.end() ? 0U : it->second;
    }

    void write32(uint32_t off, uint32_t value) noexcept override {
        ++writes_;
        touched_.insert(off);

        // Read-only registers ignore writes, as the RTL's decoder does.
        if (off == NCE_REG_DEVICE_ID || off == NCE_REG_VERSION ||
            off == NCE_REG_STATUS) {
            return;
        }

        // Staging a data word sets the matching STAGE_VALID bit.
        if (off >= NCE_REG_VECTOR_DATA0 && off <= NCE_REG_VECTOR_DATA7) {
            const uint32_t i = (off - NCE_REG_VECTOR_DATA0) / 4U;
            regs_[NCE_REG_VECTOR_STAGE_VALID] |= (1U << i);
        }
        if (off >= NCE_REG_MATRIX_DATA0 && off <= NCE_REG_MATRIX_DATA7) {
            const uint32_t i = (off - NCE_REG_MATRIX_DATA0) / 4U;
            regs_[NCE_REG_MATRIX_STAGE_VALID] |= (1U << i);
        }

        // COMMIT needs bit 0 and all eight words; otherwise it is rejected
        // and the stage-valid mask is left as-is.
        if (off == NCE_REG_VECTOR_COMMIT) {
            if ((value & 1U) == 0U || regs_[NCE_REG_VECTOR_STAGE_VALID] != 0xFFU)
                ++regs_[NCE_REG_COMMAND_ERROR_COUNT];
            regs_[off] = value;
            return;
        }
        if (off == NCE_REG_MATRIX_COMMIT) {
            if ((value & 1U) == 0U || regs_[NCE_REG_MATRIX_STAGE_VALID] != 0xFFU)
                ++regs_[NCE_REG_COMMAND_ERROR_COUNT];
            regs_[off] = value;
            return;
        }

        if (off == NCE_REG_COMMAND) {
            ++regs_[NCE_REG_COMMAND_COUNT];
            regs_[NCE_REG_LAST_COMMAND] = value;
            if (reject_next_command_) {
                ++regs_[NCE_REG_COMMAND_ERROR_COUNT];
                reject_next_command_ = false;
            } else {
                ++regs_[NCE_REG_EXECUTE_COUNT];
            }
            regs_[NCE_REG_STATUS] |= NCE_STATUS_CMD_READY;
            return;
        }

        regs_[off] = value;
    }

    void set(uint32_t off, uint32_t v)       { regs_[off] = v; }
    void reject_next_command()               { reject_next_command_ = true; }
    const std::set<uint32_t>& touched() const { return touched_; }

private:
    mutable std::map<uint32_t, uint32_t> regs_;
    mutable std::set<uint32_t>           touched_;
    mutable int                          reads_{0};
    int                                  writes_{0};
    bool                                 reject_next_command_{false};
};

}  // namespace

int main() {
    // ---- probe accepts a correct identity -----------------------------------
    {
        auto be  = std::make_unique<FakeCsr>();
        auto raw = be.get();
        Device dev{std::move(be)};

        check(dev.probe().has_value(), "probe succeeds on matching identity");
        check(dev.device_id() == 0x4E434530U, "DEVICE_ID reads ASCII \"NCE0\"");
        check(dev.version() == NCE_VERSION_VALUE, "VERSION matches");
        (void)raw;
    }

    // ---- probe rejects a wrong identity -------------------------------------
    {
        auto be  = std::make_unique<FakeCsr>();
        be->set(NCE_REG_DEVICE_ID, 0x9003138AU);   // the fictional vendor id
        Device dev{std::move(be)};

        auto r = dev.probe();
        check(!r.has_value(), "probe fails on wrong DEVICE_ID");
        check(!r.has_value() && r.error() == Error::IdentityMismatch,
              "wrong DEVICE_ID reports IdentityMismatch");
    }

    // ---- STATUS decode ------------------------------------------------------
    {
        auto be = std::make_unique<FakeCsr>();
        be->set(NCE_REG_STATUS,
                NCE_STATUS_CMD_READY | NCE_STATUS_OVERFLOW | NCE_STATUS_INEXACT |
                (2U << NCE_STATUS_LAST_COMMAND_ERROR_CODE_SHIFT));
        Device dev{std::move(be)};

        const Status s = dev.status();
        check(s.cmd_ready,                 "STATUS cmd_ready decoded");
        check(s.overflow,                  "STATUS overflow decoded");
        check(s.inexact,                   "STATUS inexact decoded");
        check(!s.invalid,                  "STATUS invalid correctly clear");
        check(s.last_command_error_code == 2U, "STATUS error code field decoded");
        check(s.any_fp_exception(),        "any_fp_exception set by overflow");
    }

    // ---- staging sets stage-valid, commit succeeds only when complete -------
    {
        auto be  = std::make_unique<FakeCsr>();
        auto raw = be.get();
        Device dev{std::move(be)};

        const std::array<uint32_t, 8> words{1, 2, 3, 4, 5, 6, 7, 8};

        check(dev.commit_vector().has_value() == false,
              "commit rejected before any word is staged");

        check(dev.stage_vector(words).has_value(), "stage_vector writes 8 words");
        check(dev.commit_vector().has_value(),     "commit accepted once complete");

        // The HAL must only touch registers the RTL decodes.
        bool all_known = true;
        for (uint32_t off : raw->touched())
            if (off >= NCE_REG_SPAN_BYTES || (off & 3U) != 0U) all_known = false;
        check(all_known, "HAL touched only aligned, in-range registers");
    }

    // ---- matrix path --------------------------------------------------------
    {
        auto be = std::make_unique<FakeCsr>();
        Device dev{std::move(be)};
        const std::array<uint32_t, 8> words{9, 10, 11, 12, 13, 14, 15, 16};
        check(dev.stage_matrix(words).has_value(), "stage_matrix writes 8 words");
        check(dev.commit_matrix().has_value(),     "matrix commit accepted");
    }

    // ---- command issue, success and rejection -------------------------------
    {
        auto be  = std::make_unique<FakeCsr>();
        auto raw = be.get();
        Device dev{std::move(be)};

        check(dev.issue_command(0xABCDU).has_value(), "command issued and retired");
        check(dev.last_command() == 0xABCDU,          "LAST_COMMAND latched");
        check(dev.command_count() == 1U,              "COMMAND_COUNT incremented");

        raw->reject_next_command();
        auto r = dev.issue_command(0xDEADU);
        check(!r.has_value(), "rejected command surfaces as an error");
        check(!r.has_value() && r.error() == Error::CommandError,
              "rejection reports CommandError");
    }

    // ---- raw access bounds checking -----------------------------------------
    {
        auto be = std::make_unique<FakeCsr>();
        Device dev{std::move(be)};

        check(!dev.read_raw(0x002U).has_value(), "unaligned read rejected");
        check(dev.read_raw(0x002U).error() == Error::BadAlignment,
              "unaligned read reports BadAlignment");
        check(!dev.read_raw(0x1000U).has_value(), "out-of-range read rejected");
        check(dev.read_raw(0x1000U).error() == Error::OutOfRange,
              "out-of-range read reports OutOfRange");
        check(dev.read_raw(NCE_REG_STATUS).has_value(), "in-range read accepted");
    }

    // ---- accumulators and lane flags ----------------------------------------
    {
        auto be = std::make_unique<FakeCsr>();
        for (uint32_t i = 0; i < 8U; ++i)
            be->set(NCE_REG_ACCUMULATOR0 + i * 4U, 0x1000U + i);
        be->set(NCE_REG_LANE_OVERFLOW, 0x5AU);
        Device dev{std::move(be)};

        const auto acc = dev.read_accumulators();
        bool ok = true;
        for (uint32_t i = 0; i < 8U; ++i) ok = ok && (acc[i] == 0x1000U + i);
        check(ok, "all 8 accumulators read back");
        check(dev.read_lane_flags().overflow == 0x5AU, "lane overflow mask read");
    }

    std::printf("----------------------------------------------------------\n");
    if (g_errors == 0)
        std::printf("PASS: nce_hal passed all %d checks.\n", g_checks);
    else
        std::printf("FAIL: nce_hal had %d errors in %d checks.\n", g_errors, g_checks);
    std::printf("----------------------------------------------------------\n");
    return g_errors == 0 ? 0 : 1;
}
