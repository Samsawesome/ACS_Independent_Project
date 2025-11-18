#include "dense_gemm.h"
#include <immintrin.h>
#include <cstring>
#include <algorithm>

#ifdef _OPENMP
#include <omp.h>
#endif

void DenseGEMM::gemm_scalar(const DenseMatrix& A, const DenseMatrix& B, 
                           DenseMatrix& C, bool transpose_a, bool transpose_b) {
    size_t M = C.rows, N = C.cols, K = A.cols;
    
    #pragma omp parallel for collapse(2)
    for (size_t i = 0; i < M; ++i) {
        for (size_t j = 0; j < N; ++j) {
            float sum = 0.0f;
            for (size_t k = 0; k < K; ++k) {
                float a_val = transpose_a ? A(k, i) : A(i, k);
                float b_val = transpose_b ? B(j, k) : B(k, j);
                sum += a_val * b_val;
            }
            C(i, j) = sum;
        }
    }
}

void DenseGEMM::gemm_avx2(const DenseMatrix& A, const DenseMatrix& B, DenseMatrix& C) {
    const size_t M = C.rows, N = C.cols, K = A.cols;
    
    C.data.assign(M * N, 0.0f);
    
    #pragma omp parallel for
    for (size_t i = 0; i < M; ++i) {
        for (size_t j = 0; j < N; j += 8) {
            __m256 accum = _mm256_setzero_ps();
            
            for (size_t k = 0; k < K; ++k) {
                __m256 a_vec = _mm256_set1_ps(A(i, k));
                __m256 b_vec = _mm256_loadu_ps(&B(k, j));
                accum = _mm256_fmadd_ps(a_vec, b_vec, accum);
            }
            
            // Handle remainder
            size_t remaining = N - j;
            if (remaining >= 8) {
                _mm256_storeu_ps(&C(i, j), accum);
            } else {
                float temp[8];
                _mm256_storeu_ps(temp, accum);
                for (size_t jj = 0; jj < remaining; ++jj) {
                    C(i, j + jj) = temp[jj];
                }
            }
        }
    }
}

void DenseGEMM::gemm_tiled(const DenseMatrix& A, const DenseMatrix& B,
                          DenseMatrix& C, size_t tile_size) {
    const size_t M = C.rows, N = C.cols, K = A.cols;
    
    C.data.assign(M * N, 0.0f);
    
    #pragma omp parallel for collapse(2)
    for (size_t i0 = 0; i0 < M; i0 += tile_size) {
        for (size_t j0 = 0; j0 < N; j0 += tile_size) {
            size_t i_end = std::min(i0 + tile_size, M);
            size_t j_end = std::min(j0 + tile_size, N);
            
            for (size_t k0 = 0; k0 < K; k0 += tile_size) {
                size_t k_end = std::min(k0 + tile_size, K);
                
                for (size_t i = i0; i < i_end; ++i) {
                    for (size_t k = k0; k < k_end; ++k) {
                        float a_val = A(i, k);
                        for (size_t j = j0; j < j_end; ++j) {
                            C(i, j) += a_val * B(k, j);
                        }
                    }
                }
            }
        }
    }
}

void DenseGEMM::process_block_avx2(size_t i_start, size_t i_end, 
                                  size_t j_start, size_t j_end,
                                  size_t k_start, size_t k_end,
                                  const DenseMatrix& A, const DenseMatrix& B,
                                  DenseMatrix& C) {
    for (size_t i = i_start; i < i_end; ++i) {
        for (size_t j = j_start; j < j_end; j += 8) {
            __m256 accum;
            
            // Load current values from C or set to zero if this is the first k-block
            if (k_start == 0) {
                accum = _mm256_setzero_ps();
            } else {
                accum = _mm256_loadu_ps(&C(i, j));
            }
            
            for (size_t k = k_start; k < k_end; ++k) {
                __m256 a_vec = _mm256_set1_ps(A(i, k));
                __m256 b_vec = _mm256_loadu_ps(&B(k, j));
                accum = _mm256_fmadd_ps(a_vec, b_vec, accum);
            }
            
            // Handle remainder at the end of j dimension
            size_t remaining = j_end - j;
            if (remaining >= 8) {
                _mm256_storeu_ps(&C(i, j), accum);
            } else {
                float temp[8];
                _mm256_storeu_ps(temp, accum);
                for (size_t jj = 0; jj < remaining; ++jj) {
                    C(i, j + jj) = temp[jj];
                }
            }
        }
    }
}

void DenseGEMM::gemm_optimized(const DenseMatrix& A, const DenseMatrix& B,
                              DenseMatrix& C, int num_threads, size_t tile_size) {
    const size_t M = C.rows, N = C.cols, K = A.cols;
    
    // FIXED: Combined tiling + AVX2 + OpenMP implementation
    #ifdef _OPENMP
    omp_set_num_threads(num_threads);
    #endif
    
    // FIXED: Initialize C to zero using vector::assign
    C.data.assign(M * N, 0.0f);
    
    // Use 2D tiling for i and j dimensions, 1D for k dimension
    #pragma omp parallel for collapse(2)
    for (size_t i0 = 0; i0 < M; i0 += tile_size) {
        for (size_t j0 = 0; j0 < N; j0 += tile_size) {
            size_t i_end = std::min(i0 + tile_size, M);
            size_t j_end = std::min(j0 + tile_size, N);
            
            // Process k dimension in tiles
            for (size_t k0 = 0; k0 < K; k0 += tile_size) {
                size_t k_end = std::min(k0 + tile_size, K);
                
                process_block_avx2(i0, i_end, j0, j_end, k0, k_end, A, B, C);
            }
        }
    }
}

void DenseGEMM::gemm_omp(const DenseMatrix& A, const DenseMatrix& B,
                        DenseMatrix& C, int num_threads) {
    #ifdef _OPENMP
    omp_set_num_threads(num_threads);
    #endif
    gemm_scalar(A, B, C);
}

void DenseGEMM::gemm_avx2_omp(const DenseMatrix& A, const DenseMatrix& B,
                             DenseMatrix& C, int num_threads) {
    #ifdef _OPENMP
    omp_set_num_threads(num_threads);
    #endif
    gemm_avx2(A, B, C);
}