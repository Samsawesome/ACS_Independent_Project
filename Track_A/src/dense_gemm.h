#pragma once
#include "matrix.h"

class DenseGEMM {
public:
    // Basic scalar implementation
    static void gemm_scalar(const DenseMatrix& A, const DenseMatrix& B, 
                           DenseMatrix& C, bool transpose_a = false, 
                           bool transpose_b = false);
    
    // Tiled implementation for cache optimization
    static void gemm_tiled(const DenseMatrix& A, const DenseMatrix& B,
                          DenseMatrix& C, size_t tile_size = 64);
    
    // AVX2 vectorized implementation
    static void gemm_avx2(const DenseMatrix& A, const DenseMatrix& B,
                         DenseMatrix& C);
    
    // AVX-512 vectorized implementation
    static void gemm_avx512(const DenseMatrix& A, const DenseMatrix& B,
                           DenseMatrix& C);
    
    // Multithreaded implementation
    static void gemm_omp(const DenseMatrix& A, const DenseMatrix& B,
                        DenseMatrix& C, int num_threads);
    
    // Combined SIMD + Multithreading
    static void gemm_avx2_omp(const DenseMatrix& A, const DenseMatrix& B,
                             DenseMatrix& C, int num_threads);
    
    // Blocking + vectorization + threading
    static void gemm_optimized(const DenseMatrix& A, const DenseMatrix& B,
                              DenseMatrix& C, int num_threads, 
                              size_t tile_size = 64);
    
private:
    // Helper functions for blocking
    static void block_gemm(size_t i_start, size_t i_end, size_t j_start, 
                          size_t j_end, size_t k_start, size_t k_end,
                          const DenseMatrix& A, const DenseMatrix& B,
                          DenseMatrix& C, size_t tile_size);
    
    // AVX2 micro-kernel for 6x16 block
    static void micro_kernel_avx2(const float* A, const float* B, float* C,
                                 size_t M, size_t N, size_t K, size_t ldA,
                                 size_t ldB, size_t ldC);
};