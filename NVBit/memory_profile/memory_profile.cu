/*
 * SPDX-FileCopyrightText: Copyright (c) 2019 NVIDIA CORPORATION & AFFILIATES.
 * All rights reserved.
 * SPDX-License-Identifier: BSD-3-Clause
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions are met:
 *
 * 1. Redistributions of source code must retain the above copyright notice, this
 * list of conditions and the following disclaimer.
 *
 * 2. Redistributions in binary form must reproduce the above copyright notice,
 * this list of conditions and the following disclaimer in the documentation
 * and/or other materials provided with the distribution.
 *
 * 3. Neither the name of the copyright holder nor the names of its
 * contributors may be used to endorse or promote products derived from
 * this software without specific prior written permission.
 *
 * THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
 * AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
 * IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
 * DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE
 * FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
 * DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
 * SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
 * CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
 * OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
 * OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

#include <assert.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <unistd.h>
#include <map>
#include <sstream>
#include <string>
#include <unordered_map>
#include <unordered_set>
#include <fstream>
#include <algorithm>

/* every tool needs to include this once */
#include "nvbit_tool.h"

/* nvbit interface file */
#include "nvbit.h"

/* for channel */
#include "utils/channel.hpp"

/* contains definition of the mem_access_t structure */
#include "common.h"

#define HEX(x)                                                            \
    "0x" << std::setfill('0') << std::setw(16) << std::hex << (uint64_t)x \
         << std::dec

#define CHANNEL_SIZE (1l << 20)

enum class RecvThreadState {
    WORKING,
    STOP,
    FINISHED,
};



/**************************** Memory Profile Collection Code Section Start ***********************************/
constexpr uint32_t MAX_SM{128};
constexpr uint32_t BLOCK_SIZE{7};   // Cache Line by default
uint64_t inline get_block_address(uint64_t addr) {return addr >> BLOCK_SIZE;}
// <ADDR, Access Count>
using MemoryBlockStats = std::unordered_map<uint64_t, uint64_t>;

// This straucture tracks the blocks for a particular logical memory type
struct MemAttr
{
    MemoryBlockStats uniqueBlocks;  // all unique blocks ever used
    uint64_t totAccesses{0};        // all accesses to this memory type
    uint64_t reads{0};
    uint64_t actMemThread{0};       // for each access this tracks how many threads are accessing memory

    // Update the Global Unique Blocks from this SM's unique blocks
    MemoryBlockStats & merge_blocks(MemoryBlockStats &gb)
    {
        for(auto &b : uniqueBlocks)
            gb[b.first] += b.second;

        return gb;
    }

    void display(std::string banner)
    {
	    if(totAccesses == 0)
		    return;
	    std::cout << banner;
	    std::cout << "\t\tAccesses: " <<  totAccesses;
	    std::cout << " LOADS: " <<  reads;
	    std::cout << " STORES: " <<  totAccesses - reads;
	    std::cout << " Average Active Memory Thread: " << std::ceil(static_cast<float>(actMemThread) / totAccesses);
	    std::cout << " Number of Unique Blocks: " << uniqueBlocks.size();
    }
};

// This structure tracks all memory accesses done by a SM
struct SMMemoryProfile
{
    MemAttr shmem_attr;     // Shared memory statistics
    MemAttr chmem_attr;     // Global memory statistics
    std::ofstream trace_fp; // memory access trace output for this SM

    // Update and record the memory access performed by a warp of this SM
    void update(uint64_t *addrs, bool is_read, int m_type)
    {
        MemAttr &attr = (m_type == static_cast<int>(InstrType::MemorySpace::SHARED)) ? shmem_attr : chmem_attr;
        std::unordered_set<uint64_t> warp_blocks;

        // collect only the unique blocks per warp
        for(auto i{0}; i < 32; i++)
        {
            if(addrs[i])
            {
                warp_blocks.insert(get_block_address(addrs[i]));
                attr.actMemThread++;
            }
        }
        attr.totAccesses++;
        if(is_read)
            attr.reads++;
        // add/updtade the SM wide unique blocks
        for(const auto &b : warp_blocks)
            attr.uniqueBlocks[b]++;
    }

    // how much capacity of shared memory been used
    uint64_t shmem_cap_util()
    {
        return shmem_attr.uniqueBlocks.size();
    }

    // Update the Global Unique Blocks from this SM's unique blocks
    MemoryBlockStats & merge_chmem_blocks(MemoryBlockStats &gb)
    {
        return chmem_attr.merge_blocks(gb);
    }

    bool hasAccesses(void)
    {
	    return (shmem_attr.totAccesses > 0) || (chmem_attr.totAccesses > 0);
    }

    void display(int id)
    {
	    if(!hasAccesses())
		    return;

	    std::cout << "SM_" << id << std::endl;
	    shmem_attr.display("\n\t>>>>> Shared Memory Profile <<<<<<<\n");
	    chmem_attr.display("\n\t>>>>> Cached Memory Profile <<<<<<<\n");
	    std::cout << std::endl;
    }
};

// Main structure that holds memory info GPU wide
SMMemoryProfile SM_Metrics[MAX_SM];

void displayMemoryHistogram(uint64_t NUM_SM, uint64_t ShMEM_Size, uint64_t ChMEM_Size)
{
    /********************* SHARED MEMORY STATS *********************/
    ShMEM_Size >>= BLOCK_SIZE;

    if(ShMEM_Size)
    {
	    uint64_t shMemUtil[6]{0, 0, 0, 0, 0, 0};  // {FULL, 75%, 50%, 25%, 0-25%, 0}

	    for(auto &sm : SM_Metrics)
	    {
            auto cap{sm.shmem_cap_util()};
            auto bin{0};
            if(cap == ShMEM_Size)
                bin = 5;
            else if(cap >= 3 * ShMEM_Size / 4)
                bin = 4;
            else if(cap >= ShMEM_Size / 2)
                bin = 3;
            else if(cap >= ShMEM_Size / 4)
                bin = 2;
            else if(cap)
                bin = 1;
            shMemUtil[bin]++;
	    }

	    std::cout << ">>>>>>>>>> Shared Mmeory Capacity Utilization Metrics (SM Capacity --> SM Count) <<<<<<<<\n";
	    std::cout << "100% " << shMemUtil[5] << std::endl;
	    std::cout << "75% " << shMemUtil[4] << std::endl;
	    std::cout << "50% " << shMemUtil[3] << std::endl;
	    std::cout << "25% " << shMemUtil[2] << std::endl;
	    std::cout << ">0% " << shMemUtil[1] << std::endl;
	    std::cout << "0% " << shMemUtil[0] << std::endl;
	    std::cout << ">>>>>>>>>>>>>>>>>>>>>><<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<\n\n";
    }
    else
	    std::cout << ">>>>>>>>>>>>>>>>> NO SHARED MEMORY UTILIZATION <<<<<<<<<<<<<<\n\n";

    
    /********************* CACHED MEMORY STATS *********************/
    
    // aggregated list of all block addresses
    ChMEM_Size >>= BLOCK_SIZE;
    MemoryBlockStats allCHMemBlocks;
    for(auto &sm : SM_Metrics)
	    sm.merge_chmem_blocks(allCHMemBlocks);

    // collect the block accesses for all SM
    std::vector<uint64_t> allBlockStats;
    auto totAcc{0};
    for(auto &b: allCHMemBlocks)
    {
        allBlockStats.push_back(b.second);
        totAcc += b.second;
    }
    if(totAcc) {
        std::sort(allBlockStats.begin(), allBlockStats.end(), std::greater<uint64_t>());

        std::cout << " >>>>>> Cached Mmeory Details <<<<<<< \n";
        std::cout << "Total Cached Memory Accesses " << totAcc << std::endl;
        std::cout << "Cache Memory Capacity Utilization " << allBlockStats.size() << " ( " << (allBlockStats.size() * 100) / ChMEM_Size << "% )\n";

        uint64_t acc_bin{0};
        uint64_t blk_count{0};
        uint64_t interval = totAcc/20;  // every 5%
	    uint64_t accPercent{0};
        for(uint64_t &blk : allBlockStats)
        {
            acc_bin += blk;
            blk_count++;
            if(acc_bin >= interval)
            {
		        accPercent += acc_bin;
                std::cout << (accPercent * 100) / totAcc << "% " << blk_count << std::endl;
                acc_bin = blk_count = 0;
            }
        }
	accPercent += acc_bin;
	std::cout << (accPercent * 100) / totAcc << "% " << blk_count << std::endl;
    }
    else
        std::cout << "No Cached Mmeory Accesses!!\n";
}
/**************************** Memory Profile Collection Code Section End ***********************************/


struct CTXstate {
    /* context id */
    int id;

    /* Channel used to communicate from GPU to CPU receiving thread */
    ChannelDev* channel_dev;
    ChannelHost channel_host;

    // After initialization, set it to WORKING to make recv thread get data,
    // parent thread sets it to STOP to make recv thread stop working.
    // recv thread sets it to FINISHED when it cleans up.
    // parent thread should wait until the state becomes FINISHED to clean up.
    volatile RecvThreadState recv_thread_done = RecvThreadState::STOP;
};

/* lock */
pthread_mutex_t mutex;
pthread_mutex_t cuda_event_mutex;

/* map to store context state */
std::unordered_map<CUcontext, CTXstate*> ctx_state_map;

/* skip flag used to avoid re-entry on the nvbit_callback when issuing
 * flush_channel kernel call */
bool skip_callback_flag = false;

/* global control variables for this tool */
uint32_t instr_begin_interval = 0;
uint32_t instr_end_interval = UINT32_MAX;
uint32_t profile_type{0};
std::string mem_type{"ALL"};
int verbose = 0;

bool inline is_requested_memory(std::string &reqType, Instr* instr)
{
	if (reqType.compare("ALL") == 0)
	   return true;
	switch(instr->getMemorySpace())
	{
	case InstrType::MemorySpace::LOCAL:
	case InstrType::MemorySpace::GLOBAL:
	   if (reqType.compare("CACHE") == 0)
	      return true;
	return false;
	case InstrType::MemorySpace::SHARED:
	case InstrType::MemorySpace::GLOBAL_TO_SHARED:
	case InstrType::MemorySpace::DISTRIBUTED_SHARED:
	   if (reqType.compare("SHMEM") == 0)
	      return true;
	return false;
	default:
	return false;
	}
}

/* opcode to id map and reverse map  */
std::map<std::string, int> opcode_to_id_map;
std::map<int, std::string> id_to_opcode_map;

/* grid launch id, incremented at every launch */
uint64_t global_grid_launch_id = 0;

void* recv_thread_fun(void* args);

void nvbit_at_init() {
    setenv("CUDA_MANAGED_FORCE_DEVICE_ALLOC", "1", 1);
    GET_VAR_INT(
        instr_begin_interval, "INSTR_BEGIN", 0,
        "Beginning of the instruction interval where to apply instrumentation");
    GET_VAR_INT(
        instr_end_interval, "INSTR_END", UINT32_MAX,
        "End of the instruction interval where to apply instrumentation");
    GET_VAR_INT(
        profile_type, "PROFILE_TYPE", 0,
        "0: Basic Profile, 1: Trace Colelction, 2: None");
    GET_VAR_STR(mem_type, "MEMORY_TYPE", "Enable tracing of the memory type");
    GET_VAR_INT(verbose, "TOOL_VERBOSE", 0, "Enable verbosity inside the tool");
    std::string pad(100, '-');
    printf("%s\n", pad.c_str());

    /* set mutex as recursive */
    pthread_mutexattr_t attr;
    pthread_mutexattr_init(&attr);
    pthread_mutexattr_settype(&attr, PTHREAD_MUTEX_RECURSIVE);
    pthread_mutex_init(&mutex, &attr);

    pthread_mutex_init(&cuda_event_mutex, &attr);
}

/* Set used to avoid re-instrumenting the same functions multiple times */
std::unordered_set<CUfunction> already_instrumented;

void instrument_function_if_needed(CUcontext ctx, CUfunction func) {
    assert(ctx_state_map.find(ctx) != ctx_state_map.end());
    CTXstate* ctx_state = ctx_state_map[ctx];

    /* Get related functions of the kernel (device function that can be
     * called by the kernel) */
    std::vector<CUfunction> related_functions =
        nvbit_get_related_functions(ctx, func);

    /* add kernel itself to the related function vector */
    related_functions.push_back(func);

    /* iterate on function */
    for (auto f : related_functions) {
        /* "recording" function was instrumented, if set insertion failed
         * we have already encountered this function */
        if (!already_instrumented.insert(f).second) {
            continue;
        }

        /* get vector of instructions of function "f" */
        const std::vector<Instr*>& instrs = nvbit_get_instrs(ctx, f);

        if (verbose) {
            printf(
                "MEMTRACE: CTX %p, Inspecting CUfunction %p name %s at address "
                "0x%lx\n",
                ctx, f, nvbit_get_func_name(ctx, f), nvbit_get_func_addr(f));
        }

        uint32_t cnt = 0;
        /* iterate on all the static instructions in the function */
        for (auto instr : instrs) {
            if (cnt < instr_begin_interval || cnt >= instr_end_interval ||
                instr->getMemorySpace() == InstrType::MemorySpace::NONE ||
                instr->getMemorySpace() == InstrType::MemorySpace::CONSTANT) {
                cnt++;
                continue;
            }
	    if (!is_requested_memory(mem_type, instr)) {
                cnt++;
                continue;
            }
            if (verbose) {
                instr->printDecoded();
            }

            if (opcode_to_id_map.find(instr->getOpcode()) ==
                opcode_to_id_map.end()) {
                int opcode_id = opcode_to_id_map.size();
                opcode_to_id_map[instr->getOpcode()] = opcode_id;
                id_to_opcode_map[opcode_id] = std::string(instr->getOpcode());
            }

            int opcode_id = opcode_to_id_map[instr->getOpcode()];
            int mref_idx = 0;
            /* iterate on the operands */
            for (int i = 0; i < instr->getNumOperands(); i++) {
                /* get the operand "i" */
                const InstrType::operand_t* op = instr->getOperand(i);

                if (op->type == InstrType::OperandType::MREF) {
                    /* insert call to the instrumentation function with its
                     * arguments */
                    nvbit_insert_call(instr, "instrument_mem", IPOINT_BEFORE);
		    /* programm counter */
		    nvbit_add_call_arg_const_val32(instr, (int)instr->getOffset());
                    /* predicate value */
                    nvbit_add_call_arg_guard_pred_val(instr);
                    /* opcode id */
                    nvbit_add_call_arg_const_val32(instr, opcode_id);
		    /* LOAD or STORE */
		    nvbit_add_call_arg_const_val32(instr, (int)instr->isLoad());
		    /* MEMTYPE: SHMEM or CHMEM */
		    nvbit_add_call_arg_const_val32(instr, (int)instr->getMemorySpace());
                    /* memory reference 64 bit address */
                    nvbit_add_call_arg_mref_addr64(instr, mref_idx);
                    /* add "space" for kernel function pointer that will be set
                     * at launch time (64 bit value at offset 0 of the dynamic
                     * arguments)*/
                    nvbit_add_call_arg_launch_val64(instr, 0);
                    /* add pointer to channel_dev*/
                    nvbit_add_call_arg_const_val64(
                        instr, (uint64_t)ctx_state->channel_dev);
                    mref_idx++;
                }
            }
            cnt++;
        }
    }
}

/* flush channel */
__global__ void flush_channel(ChannelDev* ch_dev) { ch_dev->flush(); }

void init_context_state(CUcontext ctx) {
    if (verbose) {
        printf("MEMTRACE: CREATING CONTEXT THREAD %p\n", ctx);
    }
    CTXstate* ctx_state = ctx_state_map[ctx];
    ctx_state->recv_thread_done = RecvThreadState::WORKING;
    cudaMallocManaged(&ctx_state->channel_dev, sizeof(ChannelDev));
    ctx_state->channel_host.init((int)ctx_state_map.size() - 1, CHANNEL_SIZE,
                                 ctx_state->channel_dev, recv_thread_fun, ctx);
    nvbit_set_tool_pthread(ctx_state->channel_host.get_thread());
}

static void enter_kernel_launch(CUcontext ctx, CUfunction func,
                uint64_t &grid_launch_id, nvbit_api_cuda_t cbid, void* params,
                bool stream_capture = false, bool build_graph = false) {
    // no need to sync during stream capture or manual graph build, since no
    // kernel is actually launched.
    if (!stream_capture && !build_graph) {
        /* Make sure GPU is idle */
        cudaDeviceSynchronize();
        assert(cudaGetLastError() == cudaSuccess);
    }

    /* instrument */
    instrument_function_if_needed(ctx, func);

    int nregs = 0;
    CUDA_SAFECALL(
        cuFuncGetAttribute(&nregs, CU_FUNC_ATTRIBUTE_NUM_REGS, func));

    int shmem_static_nbytes = 0;
    CUDA_SAFECALL(
        cuFuncGetAttribute(&shmem_static_nbytes,
                           CU_FUNC_ATTRIBUTE_SHARED_SIZE_BYTES, func));

    /* get function name and pc */
    const char* func_name = nvbit_get_func_name(ctx, func);
    uint64_t pc = nvbit_get_func_addr(func);

    // during stream capture or manual graph build, no kernel is launched, so
    // do not set launch argument, do not print kernel info, do not increase
    // grid_launch_id. All these should be done at graph node launch time.
    if (!stream_capture && !build_graph) {
        /* set grid launch id at launch time */
        nvbit_set_at_launch(ctx, func, (uint64_t)grid_launch_id);

        if (cbid == API_CUDA_cuLaunchKernelEx_ptsz ||
            cbid == API_CUDA_cuLaunchKernelEx) {
            cuLaunchKernelEx_params* p = (cuLaunchKernelEx_params*)params;
            printf(
                "MEMTRACE: CTX 0x%016lx - LAUNCH - Kernel pc 0x%016lx - "
                "Kernel name %s - grid launch id %ld - grid size %d,%d,%d "
                "- block size %d,%d,%d - nregs %d - shmem %d - cuda stream "
                "id %ld\n",
                (uint64_t)ctx, pc, func_name, grid_launch_id,
                p->config->gridDimX, p->config->gridDimY,
                p->config->gridDimZ, p->config->blockDimX,
                p->config->blockDimY, p->config->blockDimZ, nregs,
                shmem_static_nbytes + p->config->sharedMemBytes,
                (uint64_t)p->config->hStream);
        } else {
            cuLaunchKernel_params* p = (cuLaunchKernel_params*)params;
            printf(
                "MEMTRACE: CTX 0x%016lx - LAUNCH - Kernel pc 0x%016lx - "
                "Kernel name %s - grid launch id %ld - grid size %d,%d,%d "
                "- block size %d,%d,%d - nregs %d - shmem %d - cuda stream "
                "id %ld\n",
                (uint64_t)ctx, pc, func_name, grid_launch_id, p->gridDimX,
                p->gridDimY, p->gridDimZ, p->blockDimX, p->blockDimY,
                p->blockDimZ, nregs,
                shmem_static_nbytes + p->sharedMemBytes,
                (uint64_t)p->hStream);
        }

        // increment grid launch id for next launch
        // grid id can be changed here, since nvbit_set_at_launch() has copied
        // its value above.
        grid_launch_id++;
    }

    /* enable instrumented code to run */
    nvbit_enable_instrumented(ctx, func, true);

}

// the function is only called for non cuda graph launch cases.
static void leave_kernel_launch(CTXstate *ctx_state, uint64_t &grid_launch_id) {
    // make sure user kernel finishes to avoid deadlock
    cudaDeviceSynchronize();
    /* push a flush channel kernel */
    flush_channel<<<1, 1>>>(ctx_state->channel_dev);

    /* Make sure GPU is idle */
    cudaDeviceSynchronize();
    assert(cudaGetLastError() == cudaSuccess);
}

void nvbit_at_cuda_event(CUcontext ctx, int is_exit, nvbit_api_cuda_t cbid,
                         const char* name, void* params, CUresult* pStatus) {
    pthread_mutex_lock(&cuda_event_mutex);

    /* we prevent re-entry on this callback when issuing CUDA functions inside
     * this function */
    if (skip_callback_flag) {
        pthread_mutex_unlock(&cuda_event_mutex);
        return;
    }
    skip_callback_flag = true;

    CTXstate* ctx_state = ctx_state_map[ctx];

    switch (cbid) {
        // Identify all the possible CUDA launch events without stream
        // parameters, they will not get involved with cuda graph
        case API_CUDA_cuLaunch:
        case API_CUDA_cuLaunchGrid:
            {
                cuLaunch_params *p = (cuLaunch_params *)params;
                CUfunction func = p->f;
                if (!is_exit) {
                    enter_kernel_launch(ctx, func, global_grid_launch_id, cbid,
                                        params);
                } else {
                    leave_kernel_launch(ctx_state, global_grid_launch_id);
                }
            } break;
        // To support kernel launched by cuda graph (in addition to existing kernel
        // launche method), we need to do:
        //
        // 1. instrument kernels at cudaGraphAddKernelNode event. This is for cases
        // that kernels are manually added to a cuda graph.
        // 2. distinguish captured kernels when kernels are recorded to a graph
        // using stream capture. cudaStreamIsCapturing() tells us whether a stream
        // is capturiong.
        // 3. per-kernel instruction counters, since cuda graph can launch multiple
        // kernels at the same time.
        //
        // Three cases:
        //
        // 1. original kernel launch:
        //     1a. for any kernel launch without using a stream, we instrument it
        //     before it is launched, call cudaDeviceSynchronize after it is
        //     launched and read the instruction counter of the kernel.
        //     1b. for any kernel launch using a stream, but the stream is not
        //     capturing, we do the same thing as 1a.
        //
        //  2. cuda graph using stream capturing: if a kernel is launched in a
        //  stream and the stream is capturing. We instrument the kernel before it
        //  is launched and do nothing after it is launched, because the kernel is
        //  not running until cudaGraphLaunch. Instead, we issue a
        //  cudaStreamSynchronize after cudaGraphLaunch is done and reset the
        //  instruction counters, since a cloned graph might be launched afterwards.
        //
        //  3. cuda graph manual: we instrument the kernel added by
        //  cudaGraphAddKernelNode and do the same thing for cudaGraphLaunch as 2.
        //
        // The above method should handle most of cuda graph launch cases.
        // kernel launches with stream parameter, they can be used for cuda graph
        case API_CUDA_cuLaunchKernel_ptsz:
        case API_CUDA_cuLaunchKernel:
        case API_CUDA_cuLaunchCooperativeKernel:
        case API_CUDA_cuLaunchCooperativeKernel_ptsz:
        case API_CUDA_cuLaunchKernelEx:
        case API_CUDA_cuLaunchKernelEx_ptsz:
        case API_CUDA_cuLaunchGridAsync:
            {
                CUfunction func;
                CUstream hStream;

                if (cbid == API_CUDA_cuLaunchKernelEx_ptsz ||
                    cbid == API_CUDA_cuLaunchKernelEx) {
                    cuLaunchKernelEx_params* p =
                        (cuLaunchKernelEx_params*)params;
                    func = p->f;
                    hStream = p->config->hStream;
                } else if (cbid == API_CUDA_cuLaunchKernel_ptsz ||
                           cbid == API_CUDA_cuLaunchKernel ||
                           cbid == API_CUDA_cuLaunchCooperativeKernel_ptsz ||
                           cbid == API_CUDA_cuLaunchCooperativeKernel) {
                    cuLaunchKernel_params* p = (cuLaunchKernel_params*)params;
                    func = p->f;
                    hStream = p->hStream;
                } else {
                    cuLaunchGridAsync_params* p =
                        (cuLaunchGridAsync_params*)params;
                    func = p->f;
                    hStream = p->hStream;
                }

                cudaStreamCaptureStatus streamStatus;
                /* check if the stream is capturing, if yes, do not sync */
                CUDA_SAFECALL(cudaStreamIsCapturing(hStream, &streamStatus));
                if (!is_exit) {
                    bool stream_capture = (streamStatus == cudaStreamCaptureStatusActive);
                    enter_kernel_launch(ctx, func, global_grid_launch_id, cbid, params, stream_capture);
                } else {
                    if (streamStatus != cudaStreamCaptureStatusActive) {
                        if (verbose >= 1) {
                            printf("kernel %s not captured by cuda graph\n", nvbit_get_func_name(ctx, func));
                        }
                        leave_kernel_launch(ctx_state, global_grid_launch_id);
                    } else {
                        if (verbose >= 1) {
                            printf("kernel %s captured by cuda graph\n", nvbit_get_func_name(ctx, func));
                        }
                    }
                }
            } break;
        case API_CUDA_cuGraphAddKernelNode:
            {
                cuGraphAddKernelNode_params *p = (cuGraphAddKernelNode_params *)params;
                CUfunction func = p->nodeParams->func;

                if (!is_exit) {
                    // cuGraphAddKernelNode_params->nodeParams is the same as
                    // cuLaunchKernel_params up to sharedMemBytes
                    enter_kernel_launch(ctx, func, global_grid_launch_id, cbid, (void*)p->nodeParams, false, true);
                } 
            } break;
        case API_CUDA_cuGraphLaunch:
            {
                // if we are exiting a cuda graph launch:
                // Wait until the graph is completed using
                // cudaStreamSynchronize()
                if (is_exit) {
                    cuGraphLaunch_params *p = (cuGraphLaunch_params *)params;

                    CUDA_SAFECALL(cudaStreamSynchronize(p->hStream));
                    assert(cudaGetLastError() == cudaSuccess);
                    /* push a flush channel kernel */
                    flush_channel<<<1, 1, 0, p->hStream>>>(ctx_state->channel_dev);
                    CUDA_SAFECALL(cudaStreamSynchronize(p->hStream));
                    assert(cudaGetLastError() == cudaSuccess);
                }

            } break;
        default:
            break;
    };


    skip_callback_flag = false;
    pthread_mutex_unlock(&cuda_event_mutex);
}

void* recv_thread_fun(void* args) {
    CUcontext ctx = (CUcontext)args;

    pthread_mutex_lock(&mutex);
    /* get context state from map */
    assert(ctx_state_map.find(ctx) != ctx_state_map.end());
    CTXstate* ctx_state = ctx_state_map[ctx];

    ChannelHost* ch_host = &ctx_state->channel_host;
    pthread_mutex_unlock(&mutex);
    char* recv_buffer = (char*)malloc(CHANNEL_SIZE);

    while (ctx_state->recv_thread_done == RecvThreadState::WORKING) {
        /* receive buffer from channel */
        uint32_t num_recv_bytes = ch_host->recv(recv_buffer, CHANNEL_SIZE);
        if (num_recv_bytes > 0) {
            uint32_t num_processed_bytes = 0;
            while (num_processed_bytes < num_recv_bytes) {
                mem_access_t* ma =
                    (mem_access_t*)&recv_buffer[num_processed_bytes];

		switch(profile_type)
		{
		case 0:
		{
			SM_Metrics[ma->smid].update(ma->addrs, ma->isLoad, ma->mem_type);
		}
		break;
		case 1:
		{
                std::stringstream ss;
                ss << " sm_id "
                   << ma->smid << " - CTA " << ma->cta_id_x << ","
                   << ma->cta_id_y << "," << ma->cta_id_z << " - warp "
                   << ma->warp_id << " - " << "0x" << ma->pc << " "
		   << id_to_opcode_map[ma->opcode_id]
                   << " - ";

                for (int i = 0; i < 32; i++) {
                    ss << HEX(ma->addrs[i]) << " ";
                }

                printf("MEMTRACE: %s\n", ss.str().c_str());
		}
		break;
		default:
		break;
	    	}
                num_processed_bytes += sizeof(mem_access_t);
            }
        }
    }
    free(recv_buffer);
    ctx_state->recv_thread_done = RecvThreadState::FINISHED;
    return NULL;
}

void nvbit_at_ctx_init(CUcontext ctx) {
    pthread_mutex_lock(&mutex);
    if (verbose) {
        printf("MEMTRACE: STARTING CONTEXT %p\n", ctx);
    }
    assert(ctx_state_map.find(ctx) == ctx_state_map.end());
    CTXstate* ctx_state = new CTXstate;
    ctx_state_map[ctx] = ctx_state;
    pthread_mutex_unlock(&mutex);
}

void nvbit_tool_init(CUcontext ctx) {
    pthread_mutex_lock(&mutex);
    assert(ctx_state_map.find(ctx) != ctx_state_map.end());
    init_context_state(ctx);
    pthread_mutex_unlock(&mutex);
}

void nvbit_at_ctx_term(CUcontext ctx) {
    pthread_mutex_lock(&mutex);
    skip_callback_flag = true;
    if (verbose) {
        printf("MEMTRACE: TERMINATING CONTEXT %p\n", ctx);
    }
    /* get context state from map */
    assert(ctx_state_map.find(ctx) != ctx_state_map.end());
    CTXstate* ctx_state = ctx_state_map[ctx];

    /* Notify receiver thread and wait for receiver thread to
     * notify back */
    ctx_state->recv_thread_done = RecvThreadState::STOP;
    while (ctx_state->recv_thread_done != RecvThreadState::FINISHED)
        ;

    ctx_state->channel_host.destroy(false);
    cudaFree(ctx_state->channel_dev);
    skip_callback_flag = false;
    delete ctx_state;
    pthread_mutex_unlock(&mutex);
}

void nvbit_at_term()
{
	switch(profile_type)
	{
	case 0:
		for(auto i{0}; i < MAX_SM; i++)
		{
			SM_Metrics[i].display(i);
		}+
	break;
	case 1:
	break;
	default:
	break;
	}

	constexpr uint64_t global_mem_size = 40 * 1024 * 1024 * 1024ULL;
	constexpr uint64_t shared_mem_size = 48 * 1024ULL;
	displayMemoryHistogram(108, shared_mem_size, global_mem_size);
}

void nvbit_at_graph_node_launch(CUcontext ctx, CUfunction func,
                                          CUstream stream,
                                          uint64_t launch_handle) {
    func_config_t config = {0};
    const char* func_name = nvbit_get_func_name(ctx, func);
    uint64_t pc = nvbit_get_func_addr(func);

    pthread_mutex_lock(&mutex);
    nvbit_set_at_launch(ctx, func, (uint64_t)global_grid_launch_id, stream,
                        launch_handle);
    nvbit_get_func_config(func, &config);

    printf(
        "MEMTRACE: CTX 0x%016lx - LAUNCH - Kernel pc 0x%016lx - "
        "Kernel name %s - grid launch id %ld - grid size %d,%d,%d "
        "- block size %d,%d,%d - nregs %d - shmem %d - cuda stream "
        "id %ld\n",
        (uint64_t)ctx, pc, func_name, global_grid_launch_id, config.gridDimX,
        config.gridDimY, config.gridDimZ, config.blockDimX, config.blockDimY,
        config.blockDimZ, config.num_registers,
        config.shmem_static_nbytes + config.shmem_dynamic_nbytes,
        (uint64_t)stream);
    // grid id can be changed here, since nvbit_set_at_launch() has copied its
    // value above.
    global_grid_launch_id++;
    pthread_mutex_unlock(&mutex);
}
