#include "sparse_spmm.h"
#include <immintrin.h>

#ifdef _OPENMP
#include <omp.h>
#endif

void SparseSpMM::csr_spmm_scalar(const CSRMatrix& A, const DenseMatrix& B,
                                DenseMatrix& C) {
    const size_t M = A.rows;
    const size_t N = B.cols;
    
    // Initialize C to zero
    #pragma omp parallel for
    for (size_t i = 0; i < M * N; ++i) {
        C.data[i] = 0.0f;
    }
    
    #pragma omp parallel for
    for (size_t i = 0; i < M; ++i) {
        const size_t row_start = A.row_ptrs[i];
        const size_t row_end = A.row_ptrs[i + 1];
        
        for (size_t k_idx = row_start; k_idx < row_end; ++k_idx) {
            const int k = A.col_indices[k_idx];
            const float a_val = A.values[k_idx];
            
            for (size_t j = 0; j < N; ++j) {
                C(i, j) += a_val * B(k, j);
            }
        }
    }
}

void SparseSpMM::csr_spmm_avx2(const CSRMatrix& A, const DenseMatrix& B,
                              DenseMatrix& C) {
    const size_t M = A.rows;
    const size_t N = B.cols;
    const size_t simd_width = 8;
    
    // Initialize C to zero
    #pragma omp parallel for
    for (size_t i = 0; i < M * N; ++i) {
        C.data[i] = 0.0f;
    }
    
    #pragma omp parallel for
    for (size_t i = 0; i < M; ++i) {
        const size_t row_start = A.row_ptrs[i];
        const size_t row_end = A.row_ptrs[i + 1];
        
        for (size_t j = 0; j < N; j += simd_width) {
            size_t remaining = std::min(simd_width, N - j);
            __m256 accum;
            
            if (remaining == simd_width) {
                accum = _mm256_loadu_ps(&C(i, j));
            } else {
                // Handle partial vectors
                alignas(32) float c_buf[8] = {0};
                std::memcpy(c_buf, &C(i, j), remaining * sizeof(float));
                accum = _mm256_load_ps(c_buf);
            }
            
            for (size_t k_idx = row_start; k_idx < row_end; ++k_idx) {
                const int k = A.col_indices[k_idx];
                const float a_val = A.values[k_idx];
                __m256 a_vec = _mm256_set1_ps(a_val);
                
                if (remaining == simd_width) {
                    __m256 b_vec = _mm256_loadu_ps(&B(k, j));
                    accum = _mm256_fmadd_ps(a_vec, b_vec, accum);
                } else {
                    alignas(32) float b_buf[8] = {0};
                    std::memcpy(b_buf, &B(k, j), remaining * sizeof(float));
                    __m256 b_vec = _mm256_load_ps(b_buf);
                    accum = _mm256_fmadd_ps(a_vec, b_vec, accum);
                }
            }
            
            if (remaining == simd_width) {
                _mm256_storeu_ps(&C(i, j), accum);
            } else {
                alignas(32) float result_buf[8];
                _mm256_store_ps(result_buf, accum);
                std::memcpy(&C(i, j), result_buf, remaining * sizeof(float));
            }
        }
    }
}

void SparseSpMM::csr_spmm_omp(const CSRMatrix& A, const DenseMatrix& B,
                             DenseMatrix& C, int num_threads) {
    const size_t M = A.rows;
    const size_t N = B.cols;
    
    // Initialize C to zero
    #pragma omp parallel for num_threads(num_threads)
    for (size_t i = 0; i < M * N; ++i) {
        C.data[i] = 0.0f;
    }
    
    #ifdef _OPENMP
    omp_set_num_threads(num_threads);
    #endif
    
    #pragma omp parallel for num_threads(num_threads)
    for (size_t i = 0; i < M; ++i) {
        const size_t row_start = A.row_ptrs[i];
        const size_t row_end = A.row_ptrs[i + 1];
        
        for (size_t k_idx = row_start; k_idx < row_end; ++k_idx) {
            const int k = A.col_indices[k_idx];
            const float a_val = A.values[k_idx];
            
            for (size_t j = 0; j < N; ++j) {
                C(i, j) += a_val * B(k, j);
            }
        }
    }
}

void SparseSpMM::csr_spmm_avx2_omp(const CSRMatrix& A, const DenseMatrix& B,
                                  DenseMatrix& C, int num_threads) {
    const size_t M = A.rows;
    const size_t N = B.cols;
    const size_t simd_width = 8;
    
    // Initialize C to zero
    #pragma omp parallel for num_threads(num_threads)
    for (size_t i = 0; i < M * N; ++i) {
        C.data[i] = 0.0f;
    }
    
    #ifdef _OPENMP
    omp_set_num_threads(num_threads);
    #endif
    
    #pragma omp parallel for num_threads(num_threads)
    for (size_t i = 0; i < M; ++i) {
        const size_t row_start = A.row_ptrs[i];
        const size_t row_end = A.row_ptrs[i + 1];
        
        for (size_t j = 0; j < N; j += simd_width) {
            size_t remaining = std::min(simd_width, N - j);
            __m256 accum;
            
            if (remaining == simd_width) {
                accum = _mm256_loadu_ps(&C(i, j));
            } else {
                // Handle partial vectors
                alignas(32) float c_buf[8] = {0};
                std::memcpy(c_buf, &C(i, j), remaining * sizeof(float));
                accum = _mm256_load_ps(c_buf);
            }
            
            for (size_t k_idx = row_start; k_idx < row_end; ++k_idx) {
                const int k = A.col_indices[k_idx];
                const float a_val = A.values[k_idx];
                __m256 a_vec = _mm256_set1_ps(a_val);
                
                if (remaining == simd_width) {
                    __m256 b_vec = _mm256_loadu_ps(&B(k, j));
                    accum = _mm256_fmadd_ps(a_vec, b_vec, accum);
                } else {
                    alignas(32) float b_buf[8] = {0};
                    std::memcpy(b_buf, &B(k, j), remaining * sizeof(float));
                    __m256 b_vec = _mm256_load_ps(b_buf);
                    accum = _mm256_fmadd_ps(a_vec, b_vec, accum);
                }
            }
            
            if (remaining == simd_width) {
                _mm256_storeu_ps(&C(i, j), accum);
            } else {
                alignas(32) float result_buf[8];
                _mm256_store_ps(result_buf, accum);
                std::memcpy(&C(i, j), result_buf, remaining * sizeof(float));
            }
        }
    }
}

void SparseSpMM::csc_spmm_scalar(const CSCMatrix& A, const DenseMatrix& B,
                                DenseMatrix& C) {
    const size_t M = A.rows;
    const size_t N = B.cols;
    
    // Initialize C to zero
    #pragma omp parallel for
    for (size_t i = 0; i < M * N; ++i) {
        C.data[i] = 0.0f;
    }
    
    for (size_t j = 0; j < A.cols; ++j) {
        const size_t col_start = A.col_ptrs[j];
        const size_t col_end = A.col_ptrs[j + 1];
        
        for (size_t k_idx = col_start; k_idx < col_end; ++k_idx) {
            const int i = A.row_indices[k_idx];
            const float a_val = A.values[k_idx];
            
            for (size_t k = 0; k < N; ++k) {
                C(i, k) += a_val * B(j, k);
            }
        }
    }
}

void SparseSpMM::csc_spmm_avx2(const CSCMatrix& A, const DenseMatrix& B,
                              DenseMatrix& C) {
    // Similar to CSR but with column-wise access pattern
    const size_t M = A.rows;
    const size_t N = B.cols;
    
    // Initialize C to zero
    #pragma omp parallel for
    for (size_t i = 0; i < M * N; ++i) {
        C.data[i] = 0.0f;
    }
    
    for (size_t j = 0; j < A.cols; ++j) {
        const size_t col_start = A.col_ptrs[j];
        const size_t col_end = A.col_ptrs[j + 1];
        
        for (size_t k_idx = col_start; k_idx < col_end; ++k_idx) {
            const int i = A.row_indices[k_idx];
            const float a_val = A.values[k_idx];
            
            // Vectorize the inner loop over columns of B
            for (size_t k = 0; k < N; k += 8) {
                size_t remaining = std::min(static_cast<size_t>(8), N - k);
                
                if (remaining == 8) {
                    __m256 c_vec = _mm256_loadu_ps(&C(i, k));
                    __m256 b_vec = _mm256_loadu_ps(&B(j, k));
                    __m256 a_vec = _mm256_set1_ps(a_val);
                    c_vec = _mm256_fmadd_ps(a_vec, b_vec, c_vec);
                    _mm256_storeu_ps(&C(i, k), c_vec);
                } else {
                    // Handle remaining elements
                    for (size_t kk = k; kk < k + remaining; ++kk) {
                        C(i, kk) += a_val * B(j, kk);
                    }
                }
            }
        }
    }
}

void SparseSpMM::csc_spmm_omp(const CSCMatrix& A, const DenseMatrix& B,
                             DenseMatrix& C, int num_threads) {
    const size_t M = A.rows;
    const size_t N = B.cols;
    
    // Initialize C to zero
    #pragma omp parallel for num_threads(num_threads)
    for (size_t i = 0; i < M * N; ++i) {
        C.data[i] = 0.0f;
    }
    
    #ifdef _OPENMP
    omp_set_num_threads(num_threads);
    #endif
    
    #pragma omp parallel for num_threads(num_threads)
    for (size_t j = 0; j < A.cols; ++j) {
        const size_t col_start = A.col_ptrs[j];
        const size_t col_end = A.col_ptrs[j + 1];
        
        for (size_t k_idx = col_start; k_idx < col_end; ++k_idx) {
            const int i = A.row_indices[k_idx];
            const float a_val = A.values[k_idx];
            
            for (size_t k = 0; k < N; ++k) {
                #pragma omp atomic
                C(i, k) += a_val * B(j, k);
            }
        }
    }
}

void SparseSpMM::csr_spmm_tiled(const CSRMatrix& A, const DenseMatrix& B,
                               DenseMatrix& C, size_t tile_cols, int num_threads) {
    const size_t M = A.rows;
    const size_t N = B.cols;
    
    // Initialize C to zero
    #pragma omp parallel for num_threads(num_threads)
    for (size_t i = 0; i < M * N; ++i) {
        C.data[i] = 0.0f;
    }
    
    #ifdef _OPENMP
    omp_set_num_threads(num_threads);
    #endif
    
    #pragma omp parallel for num_threads(num_threads)
    for (size_t j0 = 0; j0 < N; j0 += tile_cols) {
        size_t j_end = std::min(j0 + tile_cols, N);
        
        for (size_t i = 0; i < M; ++i) {
            const size_t row_start = A.row_ptrs[i];
            const size_t row_end = A.row_ptrs[i + 1];
            
            for (size_t k_idx = row_start; k_idx < row_end; ++k_idx) {
                const int k = A.col_indices[k_idx];
                const float a_val = A.values[k_idx];
                
                // Process tile of columns
                for (size_t j = j0; j < j_end; ++j) {
                    C(i, j) += a_val * B(k, j);
                }
            }
        }
    }
}

void SparseSpMM::process_row_avx2(const CSRMatrix& A, const DenseMatrix& B,
                                 DenseMatrix& C, size_t row_idx) {
    const size_t N = B.cols;
    const size_t simd_width = 8;
    const size_t row_start = A.row_ptrs[row_idx];
    const size_t row_end = A.row_ptrs[row_idx + 1];
    
    for (size_t j = 0; j < N; j += simd_width) {
        size_t remaining = std::min(simd_width, N - j);
        __m256 accum = _mm256_loadu_ps(&C(row_idx, j));
        
        for (size_t k_idx = row_start; k_idx < row_end; ++k_idx) {
            const int k = A.col_indices[k_idx];
            const float a_val = A.values[k_idx];
            __m256 a_vec = _mm256_set1_ps(a_val);
            
            if (remaining == simd_width) {
                __m256 b_vec = _mm256_loadu_ps(&B(k, j));
                accum = _mm256_fmadd_ps(a_vec, b_vec, accum);
            } else {
                alignas(32) float b_buf[8] = {0};
                std::memcpy(b_buf, &B(k, j), remaining * sizeof(float));
                __m256 b_vec = _mm256_load_ps(b_buf);
                accum = _mm256_fmadd_ps(a_vec, b_vec, accum);
            }
        }
        
        if (remaining == simd_width) {
            _mm256_storeu_ps(&C(row_idx, j), accum);
        } else {
            alignas(32) float result_buf[8];
            _mm256_store_ps(result_buf, accum);
            std::memcpy(&C(row_idx, j), result_buf, remaining * sizeof(float));
        }
    }
}