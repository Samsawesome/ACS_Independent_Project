#pragma once
#include <vector>
#include <memory>
#include <cstdint>
#include <immintrin.h>  // AVX2

#ifdef _OPENMP
#include <omp.h>
#endif

enum class MatrixLayout { ROW_MAJOR, COLUMN_MAJOR };

struct DenseMatrix {
    std::vector<float> data;
    size_t rows, cols;
    MatrixLayout layout;
    
    DenseMatrix(size_t r, size_t c, MatrixLayout l = MatrixLayout::ROW_MAJOR)
        : rows(r), cols(c), layout(l) {
        data.resize(rows * cols, 0.0f);
    }
    
    float& operator()(size_t i, size_t j) {
        if (layout == MatrixLayout::ROW_MAJOR)
            return data[i * cols + j];
        else
            return data[j * rows + i];
    }
    
    const float& operator()(size_t i, size_t j) const {
        if (layout == MatrixLayout::ROW_MAJOR)
            return data[i * cols + j];
        else
            return data[j * rows + i];
    }
};

struct CSRMatrix {
    std::vector<float> values;
    std::vector<int> col_indices;
    std::vector<size_t> row_ptrs;
    size_t rows, cols;
    
    CSRMatrix(size_t r, size_t c) : rows(r), cols(c) {
        row_ptrs.resize(rows + 1, 0);
    }
};

struct CSCMatrix {
    std::vector<float> values;
    std::vector<int> row_indices;
    std::vector<size_t> col_ptrs;
    size_t rows, cols;
    
    CSCMatrix(size_t r, size_t c) : rows(r), cols(c) {
        col_ptrs.resize(cols + 1, 0);
    }
};

// Utility functions
std::unique_ptr<DenseMatrix> generate_random_dense(size_t rows, size_t cols, 
                                                  float sparsity = 0.0f);
std::unique_ptr<CSRMatrix> dense_to_csr(const DenseMatrix& dense);
std::unique_ptr<CSCMatrix> dense_to_csc(const DenseMatrix& dense);
bool validate_results(const DenseMatrix& ref, const DenseMatrix& test, 
                     float tolerance = 1e-5);