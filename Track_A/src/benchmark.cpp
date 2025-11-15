#include "benchmark.h"
#include "utils.h"
#include <fstream>
#include <random>
#include <algorithm>
#include <numeric>
#include <iostream>

// Add these static variables at the top of benchmark.cpp
size_t BenchmarkSuite::l1_cache_size = 0;
size_t BenchmarkSuite::l2_cache_size = 0;
size_t BenchmarkSuite::l3_cache_size = 0;
double BenchmarkSuite::measured_memory_bw = 0.0;

ExperimentResult BenchmarkSuite::run_dense_experiment(const ExperimentConfig& config) {
    ExperimentResult result;
    result.kernel_type = config.kernel_type;
    result.implementation = config.implementation;
    result.size = config.m;
    result.sparsity = config.sparsity;
    result.threads = config.num_threads;

    
    auto A = generate_random_dense(config.m, config.k, config.sparsity);
    auto B = generate_random_dense(config.k, config.n, 0.0f);
    DenseMatrix C(config.m, config.n);
    
    WindowsUtils::PerformanceCounter timer;

    double total_time = 0.0;
    const int iterations = 3;
    const int warmup = 3;
    for (int i = 0; i < warmup + iterations; i++) {
        // Reset C matrix
        std::fill(C.data.begin(), C.data.end(), 0.0f);
        
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
        
        if (i >= warmup) {
            total_time += timer.get_elapsed_seconds();
        }
    }

    
    result.time_seconds = total_time / iterations;
    
    result.flops = 2 * config.m * config.n * config.k;
    result.gflops = (result.flops / 1e9) / result.time_seconds;
    
    // Estimate bytes accessed
    result.bytes_accessed = (config.m * config.k + config.k * config.n + config.m * config.n) * sizeof(float);
    result.arithmetic_intensity = static_cast<double>(result.flops) / result.bytes_accessed;
    
    return result;
}

// Memory bandwidth measurement using streaming benchmark
void BenchmarkSuite::run_streaming_benchmark(size_t size_bytes, double& read_bw, double& write_bw) {
    const size_t num_elements = size_bytes / sizeof(float);
    std::vector<float> src(num_elements, 1.0f);
    std::vector<float> dst(num_elements, 0.0f);
    
    WindowsUtils::PerformanceCounter timer;
    
    // Measure write bandwidth
    timer.start();
    for (size_t i = 0; i < num_elements; i++) {
        dst[i] = src[i];
    }
    timer.stop();
    write_bw = (size_bytes / 1e9) / timer.get_elapsed_seconds();
    
    // Measure read+write bandwidth (typical memory pattern)
    std::fill(dst.begin(), dst.end(), 0.0f);
    timer.start();
    for (size_t i = 0; i < num_elements; i++) {
        dst[i] = src[i] + 1.0f;
    }
    timer.stop();
    read_bw = (2.0 * size_bytes / 1e9) / timer.get_elapsed_seconds(); // Read src + write dst
}

ExperimentResult BenchmarkSuite::run_sparse_experiment(const ExperimentConfig& config) {
    ExperimentResult result;
    result.kernel_type = config.kernel_type;
    result.implementation = config.implementation;
    result.size = config.m;
    result.sparsity = config.sparsity;
    result.threads = config.num_threads;
    
    
    auto A_dense = generate_random_dense(config.m, config.k, config.sparsity);
    auto A_csr = dense_to_csr(*A_dense);
    auto B = generate_random_dense(config.k, config.n, 0.0f);
    DenseMatrix C(config.m, config.n);
    
    WindowsUtils::PerformanceCounter timer;
    double total_time = 0.0;
    const int iterations = 3;
    const int warmup = 3;
    
    
    
    for (int i = 0; i < warmup + iterations; i++) {
        // Reset C matrix
        std::fill(C.data.begin(), C.data.end(), 0.0f);
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
        if (i >= warmup) {
            total_time += timer.get_elapsed_seconds();
        }
    }
    
    result.time_seconds = total_time / iterations;
    
    size_t nnz = A_csr->values.size();
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
    
    save_results_csv("raw_data/comprehensive_results.csv", all_results);
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
    
    save_results_csv("raw_data/speedup_analysis.csv", results);
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
        
        // Sparse implementation
        ExperimentConfig sparse_config{test_size, test_size, test_size, sparsity, 1, "csr", "simd"};
        auto sparse_result = run_sparse_experiment(sparse_config);
        results.push_back(sparse_result);
        
        std::cout << "Sparsity " << sparsity << ": Dense=" << dense_result.gflops 
                 << " GFLOP/s, Sparse=" << sparse_result.gflops << " GFLOP/s" << std::endl;
    }
    
    save_results_csv("raw_data/density_break_even.csv", results);
}

double BenchmarkSuite::measure_memory_bandwidth() {
    std::cout << "Measuring memory bandwidth..." << std::endl;
    
    // Use working set much larger than LLC
    size_t large_size = 256 * 1024 * 1024; // 256 MB
    double read_bw, write_bw;
    
    // Run multiple times and take best
    double best_bw = 0.0;
    for (int i = 0; i < 5; i++) {
        run_streaming_benchmark(large_size, read_bw, write_bw);
        double combined_bw = (read_bw + write_bw) / 2.0;
        best_bw = std::max(best_bw, combined_bw);
        std::cout << "  Run " << i+1 << ": " << combined_bw << " GB/s" << std::endl;
    }
    
    std::cout << "Best measured memory bandwidth: " << best_bw << " GB/s" << std::endl;
    return best_bw;
}

// Cache size detection using access time patterns
size_t BenchmarkSuite::detect_cache_size(size_t max_size_mb) {
    const size_t max_size = max_size_mb * 1024 * 1024;
    const size_t min_size = 4 * 1024; // 4KB
    const int samples = 1000;
    
    std::vector<double> access_times;
    std::vector<size_t> sizes;
    
    // Test different working set sizes
    for (size_t size = min_size; size <= max_size; size *= 2) {
        std::vector<float> data(size / sizeof(float), 1.0f);
        
        // Force data into cache then measure access time
        WindowsUtils::PerformanceCounter timer;
        
        // Touch all data to ensure it's in cache
        float sum = 0.0f;
        timer.start();
        for (size_t i = 0; i < data.size(); i += 64) { // Strided access
            sum += data[i];
        }
        timer.stop();
        
        double access_time = timer.get_elapsed_seconds() / (data.size() / 64);
        access_times.push_back(access_time);
        sizes.push_back(size);
        
        std::cout << "  Size: " << size/1024 << "KB, Access time: " 
                  << access_time * 1e9 << " ns" << std::endl;
    }
    
    // Simple heuristic: look for significant jumps in access time
    size_t l1_size = 32 * 1024;   // Typical L1
    size_t l2_size = 256 * 1024;  // Typical L2  
    size_t l3_size = 12 * 1024 * 1024; // Typical L3 for i5-12600K
    
    // You could add automatic detection logic here
    // For now, using typical values for i5-12600K
    std::cout << "Using typical cache sizes for i5-12600K:" << std::endl;
    std::cout << "  L1: " << l1_size/1024 << "KB" << std::endl;
    std::cout << "  L2: " << l2_size/1024 << "KB" << std::endl; 
    std::cout << "  L3: " << l3_size/1024/1024 << "MB" << std::endl;
    
    return l3_size; // Return LLC size
}

void BenchmarkSuite::characterize_cache_hierarchy() {
    std::cout << "Characterizing cache hierarchy..." << std::endl;
    
    // Detect cache sizes
    l3_cache_size = detect_cache_size(32); // Check up to 32MB
    l2_cache_size = 256 * 1024;  // 256KB typical
    l1_cache_size = 32 * 1024;   // 32KB typical
    
    // Measure memory bandwidth
    measured_memory_bw = measure_memory_bandwidth();
}

double BenchmarkSuite::measure_cache_bandwidth(size_t working_set_size) {
    double read_bw, write_bw;
    run_streaming_benchmark(working_set_size, read_bw, write_bw);
    return (read_bw + write_bw) / 2.0;
}

void BenchmarkSuite::experiment_working_set_transitions() {
    std::cout << "Running enhanced working set transitions analysis..." << std::endl;
    
    // First characterize cache hierarchy
    if (measured_memory_bw == 0.0) {
        characterize_cache_hierarchy();
    }
    
    std::vector<ExperimentResult> results;
    
    // Test sizes that cross cache boundaries
    std::vector<size_t> sizes = {
        32,    // Fits in L1
        64,    // L1 boundary  
        128,   // In L2
        256,   // L2 boundary
        512,   // In L3
        1024//,  // L3 boundary
        //2048,  // In DRAM
        //4096   // Large DRAM
        //2048 and 4096 were too big to run
    };
    
    std::cout << "Cache boundaries: L1=" << l1_cache_size/1024 << "KB, "
              << "L2=" << l2_cache_size/1024 << "KB, "
              << "L3=" << l3_cache_size/1024/1024 << "MB" << std::endl;
    
    for (size_t size : sizes) {
        size_t matrix_size = size;
        size_t working_set_bytes = 3 * matrix_size * matrix_size * sizeof(float); // A, B, C matrices
        
        ExperimentConfig config{matrix_size, matrix_size, matrix_size, 0.0f, 1, "dense", "simd"};
        auto result = run_dense_experiment(config);
        
        // Measure actual bandwidth for this working set
        double measured_bw = measure_cache_bandwidth(working_set_bytes);
        result.bytes_accessed = working_set_bytes; // More accurate estimate
        
        std::cout << "Size: " << matrix_size 
                  << ", Working Set: " << working_set_bytes / (1024*1024) << " MB"
                  << ", GFLOP/s: " << result.gflops 
                  << ", Measured BW: " << measured_bw << " GB/s"
                  << ", Cache Level: ";
        
        // Classify which cache level this fits in
        if (working_set_bytes <= l1_cache_size) {
            std::cout << "L1";
        } else if (working_set_bytes <= l2_cache_size) {
            std::cout << "L2"; 
        } else if (working_set_bytes <= l3_cache_size) {
            std::cout << "L3";
        } else {
            std::cout << "DRAM";
        }
        std::cout << std::endl;
        
        results.push_back(result);
    }
    
    save_results_csv("raw_data/working_set_transitions.csv", results);
    
    // Save cache characterization results
    std::ofstream cache_file("raw_data/cache_characterization.csv");
    cache_file << "cache_level,size_bytes,size_human,memory_bandwidth_gb_s\n";
    cache_file << "L1," << l1_cache_size << "," << l1_cache_size/1024 << "KB," << measured_memory_bw << "\n";
    cache_file << "L2," << l2_cache_size << "," << l2_cache_size/1024 << "KB," << measured_memory_bw << "\n";
    cache_file << "L3," << l3_cache_size << "," << l3_cache_size/1024/1024 << "MB," << measured_memory_bw << "\n";
    cache_file << "DRAM,0,>L3," << measured_memory_bw << "\n";
    cache_file.close();
}

void BenchmarkSuite::experiment_roofline_analysis() {
    std::cout << "Running enhanced roofline analysis..." << std::endl;
    
    if (measured_memory_bw == 0.0) {
        characterize_cache_hierarchy();
    }

    RooflineModel roof = characterize_hardware();
    std::vector<ExperimentResult> results;
    
    // Test both dense and sparse
    std::vector<size_t> sizes = {64, 128, 256, 512, 1024};
    std::vector<float> sparsities = {0.0f, 0.1f, 0.5f, 0.9f};
    
    for (size_t size : sizes) {
        for (float sparsity : sparsities) {
            if (sparsity == 0.0f) {
                // Dense case
                ExperimentConfig config{size, size, size, sparsity, 1, "dense", "simd"};
                auto result = run_dense_experiment(config);
                results.push_back(result);
                
                std::cout << "Dense Size: " << size 
                          << ", AI: " << result.arithmetic_intensity 
                          << ", GFLOP/s: " << result.gflops << std::endl;
            } else {
                // Sparse case  
                ExperimentConfig config{size, size, size, sparsity, 1, "csr", "simd"};
                auto result = run_sparse_experiment(config);
                results.push_back(result);
                
                std::cout << "Sparse Size: " << size << ", Sparsity: " << sparsity
                          << ", AI: " << result.arithmetic_intensity 
                          << ", GFLOP/s: " << result.gflops << std::endl;
            }
        }
    }
    
    save_results_csv("raw_data/roofline_analysis.csv", results);
}

RooflineModel BenchmarkSuite::characterize_hardware() {
    RooflineModel roof;
    
    // Use measured memory bandwidth instead of theoretical
    if (measured_memory_bw == 0.0) {
        characterize_cache_hierarchy();
    }
    
    // Theoretical peak (adjust for your CPU)
    roof.peak_gflops = 100.0; 
    
    // Use actual measured bandwidth
    roof.memory_bandwidth_gb_s = measured_memory_bw;
    
    std::cout << "Practical Roofline: " << roof.peak_gflops << " GFLOP/s, " 
              << roof.memory_bandwidth_gb_s << " GB/s (measured)" << std::endl;
    
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