// =============================================================================
// test_shim.cpp -- Layer 20 plugin safety tests
//
// These tests assert the SAFETY property, not features: with no transport
// implemented, the plugin must never report a completion. A plugin that
// returns ncclSuccess from isend/test without moving bytes makes NCCL believe
// a collective finished, and training silently proceeds on wrong tensors.
//
// If someone later implements a transport and flips kHaveTransport, these
// tests should be replaced with ones that verify bytes actually arrive.
// =============================================================================

#include "nccl_net_abi.h"

#include <cstdio>
#include <cstring>

extern "C" ncclNet_v6_t ncclNetPlugin_v6;

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
}  // namespace

int main() {
    auto& net = ncclNetPlugin_v6;

    // ---- the ABI table is fully populated -----------------------------------
    check(net.name != nullptr && std::strcmp(net.name, "LightRail_NCE") == 0,
          "plugin advertises its name");
    check(net.init != nullptr,    "init pointer present");
    check(net.devices != nullptr, "devices pointer present");
    check(net.isend != nullptr,   "isend pointer present");
    check(net.irecv != nullptr,   "irecv pointer present");
    check(net.test != nullptr,    "test pointer present");

    // ---- init must succeed without hardware, and not claim a device ---------
    check(net.init(nullptr) == ncclSuccess, "init succeeds with no hardware");

    int ndev = -1;
    check(net.devices(&ndev) == ncclSuccess, "devices() returns success");
    check(ndev == 0,
          "devices() reports ZERO so NCCL selects a working transport");

    // ---- the safety property ------------------------------------------------
    // Every data-path call must refuse. None may report success or completion.
    {
        char buf[64] = {};
        void* req = reinterpret_cast<void*>(0xDEADBEEFULL);

        const ncclResult_t s = net.isend(nullptr, buf, sizeof(buf), 0, nullptr, &req);
        check(s != ncclSuccess, "isend REFUSES when no transport exists");
        check(req == nullptr,   "isend does not hand back a bogus request handle");
    }

    {
        char  buf[64] = {};
        void* datas[1] = {buf};
        int   sizes[1] = {sizeof(buf)};
        int   tags[1]  = {0};
        void* req = reinterpret_cast<void*>(0xDEADBEEFULL);

        const ncclResult_t s = net.irecv(nullptr, 1, datas, sizes, tags, nullptr, &req);
        check(s != ncclSuccess, "irecv REFUSES when no transport exists");
        check(req == nullptr,   "irecv does not hand back a bogus request handle");
    }

    {
        int done = 1;                       // poisoned: must not survive as 1
        int sizes[1] = {0};
        const ncclResult_t s = net.test(nullptr, &done, sizes);
        check(s != ncclSuccess, "test REFUSES when no transport exists");
        check(done == 0,
              "test NEVER reports done=1 without a transport (the critical case)");
    }

    // ---- connection setup also refuses rather than half-working -------------
    {
        void* comm = nullptr;
        check(net.listen(0, nullptr, &comm) != ncclSuccess,  "listen refuses");
        check(net.connect(0, nullptr, &comm) != ncclSuccess, "connect refuses");
        check(net.accept(nullptr, &comm) != ncclSuccess,     "accept refuses");
    }

    // ---- argument validation ------------------------------------------------
    check(net.devices(nullptr) == ncclInvalidArgument,
          "devices(nullptr) reports InvalidArgument");
    check(net.test(nullptr, nullptr, nullptr) == ncclInvalidArgument,
          "test(nullptr) reports InvalidArgument");

    // ---- close paths are harmless -------------------------------------------
    check(net.closeSend(nullptr) == ncclSuccess,   "closeSend is safe");
    check(net.closeRecv(nullptr) == ncclSuccess,   "closeRecv is safe");
    check(net.closeListen(nullptr) == ncclSuccess, "closeListen is safe");

    std::printf("----------------------------------------------------------\n");
    if (g_errors == 0)
        std::printf("PASS: nccl shim passed all %d checks.\n", g_checks);
    else
        std::printf("FAIL: nccl shim had %d errors in %d checks.\n",
                    g_errors, g_checks);
    std::printf("----------------------------------------------------------\n");
    return g_errors == 0 ? 0 : 1;
}
