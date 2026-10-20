// =============================================================================
// nccl_net_lightrail.cpp -- Layer 20: NCCL network plugin for the NCE fabric
//
// -----------------------------------------------------------------------------
// READ THIS BEFORE CHANGING THE RETURN VALUES
// -----------------------------------------------------------------------------
// A NCCL network plugin moves other people's gradients. If isend() reports
// success without transmitting, or test() reports done without the data having
// arrived, NCCL believes the collective completed and training proceeds on
// silently wrong tensors. There is no error, no crash, and no way for the user
// to tell -- the loss curve is simply subtly wrong.
//
// So this plugin never fabricates completion. Where a capability does not yet
// exist, it says so and declines, which makes NCCL fall back to a transport
// that does work. A plugin that refuses to load costs a little bandwidth; a
// plugin that lies costs a training run and the trust in every number from it.
//
// Current state: the NCE has no fabric transport. rtl/link/ implements a
// digital die-to-die serial link between two dies on one substrate; there is
// no node-to-node network, no DMA engine, and no PCIe. Accordingly:
//
//   init()    - probes the device; succeeds only if one is actually present.
//   devices() - reports 0 devices while no transport is wired.
//
// Reporting zero devices is the mechanism by which NCCL declines to use this
// plugin. It is deliberate, and it is the whole safety property. When a real
// transport lands, implement Transport below and flip kHaveTransport; the
// data-path functions are already written against that interface.
// =============================================================================

#include "nccl_net_abi.h"

#include <cstdio>
#include <cstring>
#include <memory>
#include <string>

#include "lightrail/nce_hal.hpp"

namespace lightrail::shim {

// -----------------------------------------------------------------------------
// Transport interface the data path is written against. No implementation
// exists yet, which is exactly what kHaveTransport records.
// -----------------------------------------------------------------------------
class Transport {
public:
    virtual ~Transport() = default;
    virtual bool send(const void* data, size_t bytes, int tag) noexcept = 0;
    virtual bool recv(void* data, size_t bytes, int tag) noexcept = 0;
    virtual bool poll(bool* done, size_t* bytes) noexcept = 0;
};

// Flip to true only when a Transport implementation genuinely moves bytes
// between nodes and has been tested against hardware or a co-simulation.
inline constexpr bool kHaveTransport = false;

struct Plugin {
    std::unique_ptr<hal::Device>  device;
    std::unique_ptr<Transport>    transport;
    ncclDebugLogger_t             log{nullptr};
    bool                          probed{false};
};

Plugin& plugin() {
    static Plugin p;
    return p;
}

void logf(const char* fmt, ...) noexcept {
    // Plain stderr: the NCCL logger signature varies between versions and a
    // mismatched varargs call is its own hazard.
    std::fputs("[lightrail-nccl] ", stderr);
    std::fputs(fmt, stderr);
    std::fputc('\n', stderr);
}

}  // namespace lightrail::shim

using namespace lightrail::shim;

// -----------------------------------------------------------------------------
// Plugin entry points
// -----------------------------------------------------------------------------
extern "C" {

static ncclResult_t lrInit(ncclDebugLogger_t logFunction) {
    plugin().log = logFunction;

    // No device backend is wired yet: there is no PCIe BAR and no character
    // device for this design, so there is nothing to map. Record that we
    // probed and found nothing, rather than pretending otherwise.
    plugin().probed = true;
    plugin().device.reset();

    if constexpr (!kHaveTransport) {
        logf("no fabric transport implemented; plugin will report 0 devices "
             "so NCCL selects a working transport");
    }
    return ncclSuccess;
}

static ncclResult_t lrDevices(int* ndev) {
    if (ndev == nullptr) return ncclInvalidArgument;

    // Zero devices unless a real transport exists AND a device was mapped.
    // This is the guard that keeps NCCL from routing collectives into a path
    // that cannot carry them.
    const bool usable = kHaveTransport && plugin().device != nullptr;
    *ndev = usable ? 1 : 0;
    return ncclSuccess;
}

static ncclResult_t lrGetProperties(int, void*) {
    // Never reached while devices() reports 0.
    return ncclInternalError;
}

static ncclResult_t lrListen(int, void*, void**) {
    return ncclInternalError;
}

static ncclResult_t lrConnect(int, void*, void**) {
    return ncclInternalError;
}

static ncclResult_t lrAccept(void*, void**) {
    return ncclInternalError;
}

static ncclResult_t lrRegMr(void*, void*, int, int, void**) {
    return ncclInternalError;
}

static ncclResult_t lrDeregMr(void*, void*) {
    return ncclInternalError;
}

// The data path. These return an error rather than a fake request handle.
// Returning ncclSuccess here without moving bytes is the specific bug this
// file exists to avoid.
static ncclResult_t lrIsend(void* /*sendComm*/, void* data, int size,
                            int tag, void* /*mhandle*/, void** request) {
    if (request == nullptr) return ncclInvalidArgument;
    *request = nullptr;

    if (!kHaveTransport || plugin().transport == nullptr) {
        logf("isend called with no transport: refusing rather than reporting "
             "a completion that did not happen");
        return ncclInternalError;
    }
    if (!plugin().transport->send(data, static_cast<size_t>(size), tag))
        return ncclSystemError;
    return ncclSuccess;
}

static ncclResult_t lrIrecv(void* /*recvComm*/, int n, void** data, int* sizes,
                            int* tags, void** /*mhandles*/, void** request) {
    if (request == nullptr) return ncclInvalidArgument;
    *request = nullptr;

    if (!kHaveTransport || plugin().transport == nullptr) {
        logf("irecv called with no transport: refusing");
        return ncclInternalError;
    }
    for (int i = 0; i < n; ++i)
        if (!plugin().transport->recv(data[i], static_cast<size_t>(sizes[i]), tags[i]))
            return ncclSystemError;
    return ncclSuccess;
}

static ncclResult_t lrIflush(void*, int, void**, int*, void**, void** request) {
    if (request) *request = nullptr;
    return kHaveTransport ? ncclSuccess : ncclInternalError;
}

static ncclResult_t lrTest(void* /*request*/, int* done, int* sizes) {
    if (done == nullptr) return ncclInvalidArgument;

    // Never report done without a transport that can say so.
    if (!kHaveTransport || plugin().transport == nullptr) {
        *done = 0;
        logf("test called with no transport: reporting not-done, never done");
        return ncclInternalError;
    }

    size_t bytes = 0;
    bool   d     = false;
    if (!plugin().transport->poll(&d, &bytes)) return ncclSystemError;
    *done = d ? 1 : 0;
    if (sizes && d) sizes[0] = static_cast<int>(bytes);
    return ncclSuccess;
}

static ncclResult_t lrCloseSend(void*)   { return ncclSuccess; }
static ncclResult_t lrCloseRecv(void*)   { return ncclSuccess; }
static ncclResult_t lrCloseListen(void*) { return ncclSuccess; }

// Positional initialisation: the order must match ncclNet_v6_t exactly.
ncclNet_v6_t ncclNetPlugin_v6 = {
    /* name          */ "LightRail_NCE",
    /* init          */ lrInit,
    /* devices       */ lrDevices,
    /* getProperties */ lrGetProperties,
    /* listen        */ lrListen,
    /* connect       */ lrConnect,
    /* accept        */ lrAccept,
    /* regMr         */ lrRegMr,
    /* deregMr       */ lrDeregMr,
    /* isend         */ lrIsend,
    /* irecv         */ lrIrecv,
    /* iflush        */ lrIflush,
    /* test          */ lrTest,
    /* closeSend     */ lrCloseSend,
    /* closeRecv     */ lrCloseRecv,
    /* closeListen   */ lrCloseListen,
};

}  // extern "C"
