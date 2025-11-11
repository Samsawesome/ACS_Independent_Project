#include "matrix.h"
#include <random>
#include <algorithm>
#include <cmath>

std::unique_ptr<DenseMatrix> generate_random_dense(size_t rows, size_t cols, float sparsity) {
    auto matrix = std::make_unique<DenseMatrix>(rows, cols);
    std::random_device rd;
    std::mt19937 gen(rd());
    std::uniform_real_distribution<float> value_dist(0.0f, 1.0f);
    std::bernoulli_distribution sparsity_dist(1.0f - sparsity);
    
    for (size_t i = 0; i < rows; ++i) {
        for (size_t j = 0; j < cols; ++j) {
            if (sparsity_dist(gen)) {
                (*matrix)(i, j) = value_dist(gen);
            } else {
                (*matrix)(i, j) = 0.0f;
            }
        }
    }
    return matrix;
}

std::unique_ptr<CSRMatrix> dense_to_csr(const DenseMatrix& dense) {
    auto csr = std::make_unique<CSRMatrix>(dense.rows, dense.cols);
    
    size_t nnz = 0;
    csr->row_ptrs[0] = 0;
    
    for (size_t i = 0; i < dense.rows; ++i) {
        for (size_t j = 0; j < dense.cols; ++j) {
            float val = dense(i, j);
            if (std::abs(val) > 1e-10f) { // Consider as non-zero
                csr->values.push_back(val);
                csr->col_indices.push_back(static_cast<int>(j));
                ++nnz;
            }
        }
        csr->row_ptrs[i + 1] = nnz;
    }
    
    return csr;
}

std::unique_ptr<CSCMatrix> dense_to_csc(const DenseMatrix& dense) {
    auto csc = std::make_unique<CSCMatrix>(dense.rows, dense.cols);
    
    // First pass: count non-zeros per column
    std::vector<size_t> col_counts(dense.cols, 0);
    for (size_t j = 0; j < dense.cols; ++j) {
        for (size_t i = 0; i < dense.rows; ++i) {
            if (std::abs(dense(i, j)) > 1e-10f) {
                col_counts[j]++;
            }
        }
    }
    
    // Set up column pointers
    csc->col_ptrs[0] = 0;
    for (size_t j = 0; j < dense.cols; ++j) {
        csc->col_ptrs[j + 1] = csc->col_ptrs[j] + col_counts[j];
    }
    
    // Second pass: fill values and row indices
    csc->values.resize(csc->col_ptrs[dense.cols]);
    csc->row_indices.resize(csc->col_ptrs[dense.cols]);
    
    std::vector<size_t> col_offsets(dense.cols, 0);
    for (size_t i = 0; i < dense.rows; ++i) {
        for (size_t j = 0; j < dense.cols; ++j) {
            float val = dense(i, j);
            if (std::abs(val) > 1e-10f) {
                size_t idx = csc->col_ptrs[j] + col_offsets[j];
                csc->values[idx] = val;
                csc->row_indices[idx] = static_cast<int>(i);
                col_offsets[j]++;
            }
        }
    }
    
    return csc;
}

bool validate_results(const DenseMatrix& ref, const DenseMatrix& test, float tolerance) {
    if (ref.rows != test.rows || ref.cols != test.cols) {
        return false;
    }
    
    for (size_t i = 0; i < ref.rows; ++i) {
        for (size_t j = 0; j < ref.cols; ++j) {
            float ref_val = ref(i, j);
            float test_val = test(i, j);
            float diff = std::abs(ref_val - test_val);
            float denom = std::max(std::abs(ref_val), 1.0f);
            
            if (diff / denom > tolerance) {
                return false;
            }
        }
    }
    return true;
}