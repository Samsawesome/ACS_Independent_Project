#include "benchmark.h"
#include "utils.h"
#include <fstream>
#include <random>
#include <algorithm>
#include <numeric>
#include <iostream>



ExperimentResult BenchmarkSuite::run_dense_experiment(const ExperimentConfig& config) {
    ExperimentResult result;
    result.kernel_type = config.kernel_type;
    result.implementation = config.implementation;
    result.size = config.m;
    result.sparsity = config.sparsity;
    result.threads = config.num_threads;
    
    /* Safety check: don't run extremely large matrices
    if (config.m > 1536 || config.k > 1536 || config.n > 1536) {
        std::cout << "WARNING: Skipping large matrix " << config.m << "x" << config.k 
                 << "x" << config.n << " to avoid memory issues" << std::endl;
        result.time_seconds = 0.0;
        result.gflops = 0.0;
        return result;
    }*/
    
    auto A = generate_random_dense(config.m, config.k, config.sparsity);
    auto B = generate_random_dense(config.k, config.n, 0.0f);
    DenseMatrix C(config.m, config.n);
    
    WindowsUtils::PerformanceCounter timer;
    timer.start();
    
    try {
        if (config.implementation == "scalar") {
            DenseGEMM::gemm_scalar(*A, *B, C);
        } else if (config.implementation == "simd") {
            DenseGEMM::gemm_avx2(*A, *B, C);
        } else if (config.implementation == "omp") {
            DenseGEMM::gemm_omp(*A, *B, C, config.num_threads);
        } else if (config.implementation == "simd_omp") {
            DenseGEMM::gemm_avx2_omp(*A, *B, C, config.num_threads);
        } else {
            DenseGEMM::gemm_optimized(*A, *B, C, config.num_threads, 64);
        }
    } catch (const std::exception& e) {
        std::cout << "ERROR in dense experiment: " << e.what() << std::endl;
        result.time_seconds = 0.0;
        result.gflops = 0.0;
        return result;
    }
    
    timer.stop();
    
    result.time_seconds = timer.get_elapsed_seconds();
    
    /* Safety check: ensure reasonable timing
    if (result.time_seconds < 0.001) {
        std::cout << "WARNING: Very short execution time: " << result.time_seconds 
                 << "s for size " << config.m << std::endl;
    }*/
    
    result.flops = 2 * config.m * config.n * config.k;
    result.gflops = (result.flops / 1e9) / result.time_seconds;
    
    // Estimate bytes accessed
    result.bytes_accessed = (config.m * config.k + config.k * config.n + config.m * config.n) * sizeof(float);
    result.arithmetic_intensity = static_cast<double>(result.flops) / result.bytes_accessed;
    
    return result;
}

ExperimentResult BenchmarkSuite::run_sparse_experiment(const ExperimentConfig& config) {
    ExperimentResult result;
    result.kernel_type = config.kernel_type;
    result.implementation = config.implementation;
    result.size = config.m;
    result.sparsity = config.sparsity;
    result.threads = config.num_threads;
    
    /* Safety check for matrix sizes
    if (config.m > 1536 || config.k > 1536 || config.n > 1536) {
        std::cout << "WARNING: Skipping large sparse matrix " << config.m << "x" << config.k 
                 << "x" << config.n << std::endl;
        result.time_seconds = 0.0;
        result.gflops = 0.0;
        return result;
    }*/
    
    auto A_dense = generate_random_dense(config.m, config.k, config.sparsity);
    auto A_csr = dense_to_csr(*A_dense);
    auto B = generate_random_dense(config.k, config.n, 0.0f);
    DenseMatrix C(config.m, config.n);
    
    WindowsUtils::PerformanceCounter timer;
    timer.start();
    
    try {
        if (config.kernel_type == "csr") {
            if (config.implementation == "scalar") {
                SparseSpMM::csr_spmm_scalar(*A_csr, *B, C);
            } else if (config.implementation == "simd") {
                SparseSpMM::csr_spmm_avx2(*A_csr, *B, C);
            } else if (config.implementation == "omp") {
                SparseSpMM::csr_spmm_omp(*A_csr, *B, C, config.num_threads);
            } else {
                SparseSpMM::csr_spmm_avx2_omp(*A_csr, *B, C, config.num_threads);
            }
        }
    } catch (const std::exception& e) {
        std::cout << "ERROR in sparse experiment: " << e.what() << std::endl;
        result.time_seconds = 0.0;
        result.gflops = 0.0;
        return result;
    }
    
    timer.stop();
    
    size_t nnz = A_csr->values.size();
    result.time_seconds = timer.get_elapsed_seconds();
    result.flops = 2 * nnz * config.n;
    result.gflops = (result.flops / 1e9) / result.time_seconds;
    result.cpnz = timer.get_cycle_count() / static_cast<double>(nnz);
    
    // Estimate bytes accessed for sparse
    result.bytes_accessed = (nnz * (sizeof(float) + sizeof(int)) + 
                           A_csr->row_ptrs.size() * sizeof(size_t) + 
                           config.k * config.n * sizeof(float) + 
                           config.m * config.n * sizeof(float));
    result.arithmetic_intensity = static_cast<double>(result.flops) / result.bytes_accessed;
    
    return result;
}

void BenchmarkSuite::run_comprehensive_benchmarks(const BenchmarkConfig& config) {
    std::cout << "Running comprehensive benchmarks..." << std::endl;
    
    std::vector<ExperimentResult> all_results;
    
    for (size_t size : config.sizes) {
        for (float sparsity : config.sparsities) {
            for (int threads : config.thread_counts) {
                std::cout << "Testing: size=" << size << ", sparsity=" << sparsity 
                         << ", threads=" << threads << std::endl;
                
                // Dense experiments
                ExperimentConfig dense_config{size, size, size, sparsity, threads, "dense", "optimized"};
                auto dense_result = run_dense_experiment(dense_config);
                all_results.push_back(dense_result);
                
                // Sparse experiments (only for meaningful sparsity levels)
                if (sparsity > 0.001f) {
                    ExperimentConfig sparse_config{size, size, size, sparsity, threads, "csr", "optimized"};
                    auto sparse_result = run_sparse_experiment(sparse_config);
                    all_results.push_back(sparse_result);
                }
            }
        }
    }
    
    save_results_csv("comprehensive_results.csv", all_results);
}

void BenchmarkSuite::experiment_correctness_validation() {
    std::cout << "Running correctness validation..." << std::endl;
    
    // Test with small matrices for quick validation
    size_t m = 256, k = 256, n = 256;
    float sparsity = 0.1f;
    
    auto A = generate_random_dense(m, k, sparsity);
    auto B = generate_random_dense(k, n, 0.0f); // Dense B
    
    // Reference result using simple implementation
    DenseMatrix C_ref(m, n);
    DenseGEMM::gemm_scalar(*A, *B, C_ref);
    
    // Test dense implementations
    DenseMatrix C_dense(m, n);
    DenseGEMM::gemm_avx2(*A, *B, C_dense);
    
    if (!validate_results(C_ref, C_dense)) {
        std::cerr << "ERROR: Dense AVX2 implementation failed validation!" << std::endl;
    } else {
        std::cout << "Dense AVX2 implementation: PASS" << std::endl;
    }
    
    // Test sparse implementation
    auto A_csr = dense_to_csr(*A);
    DenseMatrix C_sparse(m, n);
    SparseSpMM::csr_spmm_avx2(*A_csr, *B, C_sparse);
    
    if (!validate_results(C_ref, C_sparse)) {
        std::cerr << "ERROR: Sparse CSR implementation failed validation!" << std::endl;
    } else {
        std::cout << "Sparse CSR implementation: PASS" << std::endl;
    }
    
    std::cout << "All correctness tests completed!" << std::endl;
}

void BenchmarkSuite::experiment_simd_threading_speedup() {
    std::cout << "Running SIMD and threading speedup analysis..." << std::endl;
    
    std::vector<ExperimentResult> results;
    size_t test_size = 1024; // Reduced for faster testing
    float sparsity = 0.0f; // Dense for this experiment
    
    // Test different implementations
    std::vector<std::pair<std::string, int>> test_cases = {
        {"scalar", 1},
        {"simd", 1},
        {"omp", 2},
        {"omp", 4},
        {"omp", 8},
        {"simd_omp", 2},
        {"simd_omp", 4},
        {"simd_omp", 8}
    };
    
    auto A = generate_random_dense(test_size, test_size, sparsity);
    auto B = generate_random_dense(test_size, test_size, 0.0f);
    
    for (const auto& test_case : test_cases) {
        const auto& impl = test_case.first;
        int threads = test_case.second;
        
        ExperimentConfig config{test_size, test_size, test_size, sparsity, threads, "dense", impl};
        auto result = run_dense_experiment(config);
        
        results.push_back(result);
        
        std::cout << "Implementation: " << impl << ", Threads: " << threads 
                 << ", GFLOP/s: " << result.gflops << std::endl;
    }
    
    save_results_csv("speedup_analysis.csv", results);
}

void BenchmarkSuite::experiment_density_break_even() {
    std::cout << "Running density break-even analysis..." << std::endl;
    
    std::vector<ExperimentResult> results;
    size_t test_size = 1024;
    std::vector<float> sparsities = {0.001f, 0.005f, 0.01f, 0.02f, 0.05f, 0.1f, 0.2f, 0.5f};
    
    for (float sparsity : sparsities) {
        std::cout << "Testing sparsity: " << sparsity << std::endl;
        
        // Dense implementation
        ExperimentConfig dense_config{test_size, test_size, test_size, sparsity, 1, "dense", "simd"};
        auto dense_result = run_dense_experiment(dense_config);
        results.push_back(dense_result);
        
        // Sparse implementation - ALWAYS run for all sparsities, including 0.001
        ExperimentConfig sparse_config{test_size, test_size, test_size, sparsity, 1, "csr", "simd"};
        auto sparse_result = run_sparse_experiment(sparse_config);
        results.push_back(sparse_result);
        
        std::cout << "Sparsity " << sparsity << ": Dense=" << dense_result.gflops 
                 << " GFLOP/s, Sparse=" << sparse_result.gflops << " GFLOP/s" << std::endl;
    }
    
    save_results_csv("density_break_even.csv", results);
}

void BenchmarkSuite::experiment_working_set_transitions() {
    std::cout << "Running working set transitions analysis..." << std::endl;
    
    std::vector<ExperimentResult> results;
    // Use sizes that fit in cache/memory without overflow
    std::vector<size_t> sizes = {64, 128, 256, 512, 1024}; 
    
    for (size_t size : sizes) {
        ExperimentConfig config{size, size, size, 0.0f, 1, "dense", "simd"};
        auto result = run_dense_experiment(config);
        
        results.push_back(result);
        std::cout << "Size: " << size << ", GFLOP/s: " << result.gflops << std::endl;
         
    }
    
    save_results_csv("working_set_transitions.csv", results);
}

void BenchmarkSuite::experiment_roofline_analysis() {
    std::cout << "Running roofline analysis..." << std::endl;
    
    RooflineModel roof = characterize_hardware();
    std::vector<ExperimentResult> results;
    
    // Use safe sizes
    std::vector<size_t> sizes = {64, 128, 256, 512, 1024};
    
    for (size_t size : sizes) {
        ExperimentConfig config{size, size, size, 0.0f, 1, "dense", "simd"};
        auto result = run_dense_experiment(config);
        
        
        results.push_back(result);
        std::cout << "Size: " << size << ", AI: " << result.arithmetic_intensity 
                    << ", GFLOP/s: " << result.gflops << std::endl;
        
    }
    
    save_results_csv("roofline_analysis.csv", results);
}

RooflineModel BenchmarkSuite::characterize_hardware() {
    RooflineModel roof;
    
    // These are theoretical peaks - adjust based on your CPU
    // i5-12600K has practical ~50 GB/s memory bandwidth
    // AVX2 = 8 flop/cycle, 6 3.7GHz cores, 4 2.8GHz cores, averages to 133.6 GFLOPs
    //put down 100 has a practical estimate
    roof.peak_gflops = 100.0; 
    roof.memory_bandwidth_gb_s = 50.0; 
    
    std::cout << "Theoretical Roofline: " << roof.peak_gflops << " GFLOP/s, " 
              << roof.memory_bandwidth_gb_s << " GB/s" << std::endl;
    
    return roof;
}

void BenchmarkSuite::save_results_csv(const std::string& filename,
                                     const std::vector<ExperimentResult>& results) {
    std::ofstream file(filename);
    file << "kernel_type,implementation,size,sparsity,threads,time_seconds,gflops,cpnz,flops,bytes_accessed,arithmetic_intensity\n";
    
    for (const auto& result : results) {
        file << result.kernel_type << ","
             << result.implementation << ","
             << result.size << ","
             << result.sparsity << ","
             << result.threads << ","
             << result.time_seconds << ","
             << result.gflops << ","
             << result.cpnz << ","
             << result.flops << ","
             << result.bytes_accessed << ","
             << result.arithmetic_intensity << "\n";
    }
    
    file.close();
    std::cout << "Results saved to " << filename << std::endl;
}