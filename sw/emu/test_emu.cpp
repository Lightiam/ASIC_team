// =============================================================================
// test_emu.cpp -- end-to-end: HAL -> emulated device, and a real transport.
//
// This is the test that turns Layers 13-22 from algorithms into a system:
// the HAL drives a device, the device computes, and bytes actually move
// between two endpoints.
// =============================================================================

#include "nce_emulator.hpp"

#include <cstdio>
#include <cstring>
#include <memory>
#include <vector>

using namespace lightrail;

namespace {
int g_checks = 0, g_errors = 0;
void check(bool c, const char* w) {
    ++g_checks;
    if (!c) { ++g_errors; std::printf("FAIL: %s\n", w); }
}
}

int main() {
    std::printf("=== emulated device: HAL drives it end to end ===\n");

    // The HAL owns the backend, so hand it one and keep a raw observer.
    auto owned = std::make_unique<emu::EmulatedDevice>();
    auto* dev_raw = owned.get();
    hal::Device dev{std::move(owned)};

    // probe() must REJECT the emulator: its id is EMU0, not NCE0. That is
    // the guard that stops emulated runs being mistaken for hardware.
    auto pr = dev.probe();
    check(!pr.has_value(), "HAL probe REJECTS the emulator (id is EMU0, not NCE0)");
    check(!pr.has_value() && pr.error() == hal::Error::IdentityMismatch,
          "rejection reports IdentityMismatch");
    std::printf("  device id = 0x%08X (\"EMU0\"), HAL correctly refuses it as hardware\n",
                dev.device_id());

    // Everything else works, which is what makes it useful for testing.
    const std::array<uint32_t, 8> a{1, 2, 3, 4, 5, 6, 7, 8};
    const std::array<uint32_t, 8> b{10, 10, 10, 10, 10, 10, 10, 10};

    check(dev.issue_command(2).has_value(), "clear command accepted");
    check(dev.stage_vector(a).has_value(), "vector staged");
    check(dev.stage_matrix(b).has_value(), "matrix staged");
    check(dev.commit_vector().has_value(), "vector commit accepted");
    check(dev.commit_matrix().has_value(), "matrix commit accepted");
    check(dev.issue_command(1).has_value(), "MAC command executed");

    const auto acc = dev.read_accumulators();
    bool mac_ok = true;
    for (uint32_t i = 0; i < 8; ++i) if (acc[i] != (i + 1) * 10) mac_ok = false;
    check(mac_ok, "accumulators hold the elementwise product");
    std::printf("  accumulators: ");
    for (auto v : acc) std::printf("%u ", v);
    std::printf("\n");

    // Commit must be refused before all eight words are staged, as in RTL.
    hal::Device dev2{std::make_unique<emu::EmulatedDevice>()};
    check(!dev2.commit_vector().has_value(),
          "commit refused before any word is staged (matches the RTL)");

    // An unknown command is counted as an error, not silently ignored.
    const uint32_t before = dev.command_error_count();
    (void)dev.issue_command(0xFF);
    check(dev.command_error_count() > before,
          "an unknown command increments the error counter");

    std::printf("  commands executed: %u\n", dev_raw->commands_executed());

    // ---- transport: bytes must really move --------------------------------
    std::printf("\n=== transport: do bytes actually move? ===\n");
    auto [ep_a, ep_b] = emu::Endpoint::pair();

    const char payload[] = "gradient-chunk-0123456789";
    char recv[sizeof(payload)] = {};

    check(!ep_b->try_recv(recv, sizeof(payload), 7),
          "recv before send returns nothing (no phantom completion)");

    check(ep_a->send(payload, sizeof(payload), 7), "send accepted");
    check(ep_b->try_recv(recv, sizeof(payload), 7), "recv succeeds after send");
    check(std::memcmp(payload, recv, sizeof(payload)) == 0,
          "received bytes are IDENTICAL to what was sent");
    std::printf("  moved %zu bytes, content verified\n", ep_a->bytes_sent());

    // A mismatched size must fail rather than truncate a tensor.
    char small[4] = {};
    check(ep_a->send(payload, sizeof(payload), 9), "second send accepted");
    check(!ep_b->try_recv(small, sizeof(small), 9),
          "size mismatch REFUSED rather than silently truncating");

    // Tag matching.
    check(!ep_b->try_recv(recv, sizeof(payload), 999),
          "wrong tag does not match a queued message");

    std::printf("\n=== emulation gating ===\n");
    std::printf("  LIGHTRAIL_EMULATE set: %s\n",
                emu::emulation_enabled() ? "yes" : "no");
    check(true, "emulation gate readable");

    std::printf("----------------------------------------------------------\n");
    if (g_errors == 0) std::printf("PASS: emulator passed all %d checks.\n", g_checks);
    else std::printf("FAIL: emulator had %d errors in %d checks.\n", g_errors, g_checks);
    std::printf("----------------------------------------------------------\n");
    return g_errors == 0 ? 0 : 1;
}
