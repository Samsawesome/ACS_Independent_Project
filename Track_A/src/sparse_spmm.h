#pragma once
#include "matrix.h"

class SparseSpMM {
public:
    // CSR SpMM implementations
    
    // Scalar CSR SpMM
    static void csr_spmm_scalar(const CSRMatrix& A, const DenseMatrix& B,
                               DenseMatrix& C);
    
    // Vectorized CSR SpMM using AVX2
    static void csr_spmm_avx2(const CSRMatrix& A, const DenseMatrix& B,
                             DenseMatrix& C);
    
    // Multithreaded CSR SpMM
    static void csr_spmm_omp(const CSRMatrix& A, const DenseMatrix& B,
                            DenseMatrix& C, int num_threads);
    
    // Vectorized + Multithreaded CSR SpMM
    static void csr_spmm_avx2_omp(const CSRMatrix& A, const DenseMatrix& B,
                                 DenseMatrix& C, int num_threads);
    
    // CSC SpMM implementations
    static void csc_spmm_scalar(const CSCMatrix& A, const DenseMatrix& B,
                               DenseMatrix& C);
    
    static void csc_spmm_avx2(const CSCMatrix& A, const DenseMatrix& B,
                             DenseMatrix& C);
    
    static void csc_spmm_omp(const CSCMatrix& A, const DenseMatrix& B,
                            DenseMatrix& C, int num_threads);
    
    // Tiled column processing for better cache behavior
    static void csr_spmm_tiled(const CSRMatrix& A, const DenseMatrix& B,
                              DenseMatrix& C, size_t tile_cols = 64,
                              int num_threads = 1);
    
private:
    // Helper function for vectorized row processing
    static void process_row_avx2(const CSRMatrix& A, const DenseMatrix& B,
                                DenseMatrix& C, size_t row_idx);
};