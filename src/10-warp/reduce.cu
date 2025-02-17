#include "error.cuh"
#include <stdio.h>
#include <cooperative_groups.h>
using namespace cooperative_groups;

#ifdef USE_DP
    typedef double real;
#else
    typedef float real;
#endif

const int NUM_REPEATS = 10;
const int N = 100000000;
const int block_size = 128;
const int repeat_size = 10;

void timing(real *h_x, real *d_x, const int method);
real reduce(real *d_x, const int method);

int main(void)
{
    const int M = sizeof(real) * N;
    real *h_x = (real *) malloc(M);
    for (int n = 0; n < N; ++n)
    {
        h_x[n] = 1.23;
    }
    real *d_x;
    CHECK(cudaMalloc(&d_x, M));

    printf("\nusing syncwarp:\n");
    timing(h_x, d_x, 0);
    printf("\nusing shfl:\n");
    timing(h_x, d_x, 1);
    printf("\nusing cooperative group:\n");
    timing(h_x, d_x, 2);

    free(h_x);
    CHECK(cudaFree(d_x));
    return 0;
}

void timing(real *h_x, real *d_x, const int method)
{
    real sum = 0;
    float t_sum = 0;
    float t2_sum = 0;

    for (int repeat = 0; repeat < NUM_REPEATS * 2; ++repeat)
    {
        const int M = sizeof(real) * N;
        CHECK(cudaMemcpy(d_x, h_x, M, cudaMemcpyHostToDevice));

        cudaEvent_t start, stop;
        CHECK(cudaEventCreate(&start));
        CHECK(cudaEventCreate(&stop));
        CHECK(cudaEventRecord(start));

        sum = reduce(d_x, method); 

        CHECK(cudaEventRecord(stop));
        CHECK(cudaEventSynchronize(stop));
        float elapsed_time;
        CHECK(cudaEventElapsedTime(&elapsed_time, start, stop));
        printf("Time = %g ms.\n", elapsed_time);

        if (repeat >= NUM_REPEATS)
        {
            t_sum += elapsed_time;
            t2_sum += elapsed_time * elapsed_time;
        }

        CHECK(cudaEventDestroy(start));
        CHECK(cudaEventDestroy(stop));
    }

    const float t_ave = t_sum / NUM_REPEATS;
    const float t_err = sqrt(t2_sum / NUM_REPEATS - t_ave * t_ave);
    printf("Time = %g +- %g ms.\n", t_ave, t_err);

    printf("sum = %f.\n", sum);
}

void __global__ reduce_syncwarp(real *d_x, real *d_y, const int N)
{
    const int tid = threadIdx.x;
    const int bid = blockIdx.x;
    extern __shared__ real s_y[];

    real y = 0.0;
    const int stride = blockDim.x * gridDim.x;
    for (int n = bid * blockDim.x + tid; n < N; n += stride)
    {
        y += d_x[n];
    }
    s_y[tid] = y;
    __syncthreads();

    for (int offset = blockDim.x >> 1; offset >= 32; offset >>= 1)
    {
        if (tid < offset)
        {
            s_y[tid] += s_y[tid + offset];
        }
        __syncthreads();
    }

    for (int offset = 16; offset > 0; offset >>= 1)
    {
        if (tid < offset)
        {
            s_y[tid] += s_y[tid + offset];
        }
        __syncwarp();
    }

    if (tid == 0)
    {
        d_y[bid] = s_y[0];
    }
}

void __global__ reduce_shfl(real *d_x, real *d_y, const int N)
{
    const int tid = threadIdx.x;
    const int bid = blockIdx.x;
    extern __shared__ real s_y[];

    real y = 0.0;
    const int stride = blockDim.x * gridDim.x;
    for (int n = bid * blockDim.x + tid; n < N; n += stride)
    {
        y += d_x[n];
    }
    s_y[tid] = y;
    __syncthreads();

    for (int offset = blockDim.x >> 1; offset >= 32; offset >>= 1)
    {
        if (tid < offset)
        {
            s_y[tid] += s_y[tid + offset];
        }
        __syncthreads();
    }

    y = s_y[tid];

    #define FULL_MASK 0xffffffff
    for (int offset = 16; offset > 0; offset >>= 1)
    {
        y += __shfl_down_sync(FULL_MASK, y, offset);
    }

    if (tid == 0)
    {
        d_y[bid] = y;
    }
}

void __global__ reduce_cp(real *d_x, real *d_y, const int N)
{
    const int tid = threadIdx.x;
    const int bid = blockIdx.x;
    extern __shared__ real s_y[];

    real y = 0.0;
    const int stride = blockDim.x * gridDim.x;
    for (int n = bid * blockDim.x + tid; n < N; n += stride)
    {
        y += d_x[n];
    }
    s_y[tid] = y;
    __syncthreads();

    for (int offset = blockDim.x >> 1; offset >= 32; offset >>= 1)
    {
        if (tid < offset)
        {
            s_y[tid] += s_y[tid + offset];
        }
        __syncthreads();
    }

    y = s_y[tid];

    thread_block_tile<32> g = tiled_partition<32>(this_thread_block());
    for (int i = g.size() >> 1; i > 0; i >>= 1)
    {
        y += g.shfl_down(y, i);
    }

    if (tid == 0)
    {
        d_y[bid] = y;
    }
}

real reduce(real *d_x, const int method)
{
    int grid_size = (N + block_size - 1) / block_size;
    grid_size = (grid_size + repeat_size - 1) / repeat_size;
    const int ymem = sizeof(real) * grid_size;
    const int smem = sizeof(real) * block_size;

    real h_y[1] = {0};
    real *d_y;
    CHECK(cudaMalloc(&d_y, ymem));

    switch (method)
    {
        case 0:
            reduce_syncwarp<<<grid_size, block_size, smem>>>(d_x, d_y, N);
            if (grid_size > 1)
            {
                reduce_syncwarp<<<1, 1024, sizeof(real) * 1024>>>(d_y, d_y, grid_size);
            }
            break;
        case 1:
            reduce_shfl<<<grid_size, block_size, smem>>>(d_x, d_y, N);
            if (grid_size > 1)
            {
                reduce_shfl<<<1, 1024, sizeof(real) * 1024>>>(d_y, d_y, grid_size);
            }
            break;
        case 2:
            reduce_cp<<<grid_size, block_size, smem>>>(d_x, d_y, N);
            if (grid_size > 1)
            {
                reduce_cp<<<1, 1024, sizeof(real) * 1024>>>(d_y, d_y, grid_size);
            }
            break;
        default:
            printf("Wrong method.\n");
            exit(1);
    }

    CHECK(cudaMemcpy(h_y, d_y, sizeof(real), cudaMemcpyDeviceToHost));
    CHECK(cudaFree(d_y));

    return h_y[0];
}


