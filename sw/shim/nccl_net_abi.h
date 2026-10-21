// =============================================================================
// nccl_net_abi.h -- minimal vendored subset of the NCCL network plugin ABI
//
// Only the declarations this plugin actually uses. Vendored so the shim builds
// and is testable without NCCL installed; when building against a real NCCL,
// define LIGHTRAIL_USE_SYSTEM_NCCL and the real <nccl_net.h> is used instead.
//
// The struct layout below must match the NCCL v6 plugin ABI exactly. It is
// positional: NCCL loads the symbol and calls through function pointers by
// offset, so reordering a member silently calls the wrong function.
// =============================================================================

#pragma once

#ifdef LIGHTRAIL_USE_SYSTEM_NCCL
#include <nccl.h>
#include <nccl_net.h>
#else

#include <stdint.h>

typedef enum {
    ncclSuccess                =  0,
    ncclUnhandledCudaError     =  1,
    ncclSystemError            =  2,
    ncclInternalError          =  3,
    ncclInvalidArgument        =  4,
    ncclInvalidUsage           =  5,
    ncclRemoteError            =  6,
    ncclInProgress             =  7,
} ncclResult_t;

#define NCCL_PTR_HOST 0x1
#define NCCL_PTR_CUDA 0x2

typedef void (*ncclDebugLogger_t)(void*, int, const char*, int, const char*, ...);

typedef struct {
    const char* name;
    ncclResult_t (*init)(ncclDebugLogger_t logFunction);
    ncclResult_t (*devices)(int* ndev);
    ncclResult_t (*getProperties)(int dev, void* props);
    ncclResult_t (*listen)(int dev, void* handle, void** listenComm);
    ncclResult_t (*connect)(int dev, void* handle, void** sendComm);
    ncclResult_t (*accept)(void* listenComm, void** recvComm);
    ncclResult_t (*regMr)(void* comm, void* data, int size, int type, void** mhandle);
    ncclResult_t (*deregMr)(void* comm, void* mhandle);
    ncclResult_t (*isend)(void* sendComm, void* data, int size, int tag,
                          void* mhandle, void** request);
    ncclResult_t (*irecv)(void* recvComm, int n, void** data, int* sizes, int* tags,
                          void** mhandles, void** request);
    ncclResult_t (*iflush)(void* recvComm, int n, void** data, int* sizes,
                           void** mhandles, void** request);
    ncclResult_t (*test)(void* request, int* done, int* sizes);
    ncclResult_t (*closeSend)(void* sendComm);
    ncclResult_t (*closeRecv)(void* recvComm);
    ncclResult_t (*closeListen)(void* listenComm);
} ncclNet_v6_t;

#endif  // LIGHTRAIL_USE_SYSTEM_NCCL
