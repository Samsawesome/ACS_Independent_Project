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
    
    // Multithreaded implementation
    static void gemm_omp(const DenseMatrix& A, const DenseMatrix& B,
                        DenseMatrix& C, int num_threads);
    
    // Combined SIMD + Multithreading
    static void gemm_avx2_omp(const DenseMatrix& A, const DenseMatrix& B,
                             DenseMatrix& C, int num_threads);
    
    // Blocking + vectorization + threading (FIXED: now properly combines all optimizations)
    static void gemm_optimized(const DenseMatrix& A, const DenseMatrix& B,
                              DenseMatrix& C, int num_threads, 
                              size_t tile_size = 64);

private:
    // Helper function for AVX2 block processing
    static void process_block_avx2(size_t i_start, size_t i_end, 
                                  size_t j_start, size_t j_end,
                                  size_t k_start, size_t k_end,
                                  const DenseMatrix& A, const DenseMatrix& B,
                                  DenseMatrix& C);
};