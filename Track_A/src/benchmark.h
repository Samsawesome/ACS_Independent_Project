#pragma once
#include "matrix.h"
#include "dense_gemm.h"
#include "sparse_spmm.h"
#include "utils.h"
#include <vector>
#include <string>
#include <map>
#include <iostream>
#include <algorithm>

// Define ExperimentResult struct first
struct ExperimentResult {
    double time_seconds = 0.0;
    double gflops = 0.0;
    double cpnz = 0.0;  // Cycles per nonzero (for sparse)
    size_t flops = 0;
    size_t bytes_accessed = 0;
    double arithmetic_intensity = 0.0;
    std::string kernel_type = "";
    std::string implementation = "";
    size_t size = 0;
    float sparsity = 0.0f;
    int threads = 1;
};

// Define ExperimentConfig struct
struct ExperimentConfig {
    size_t m, k, n;  // Matrix dimensions
    float sparsity;   // Sparsity level for A
    int num_threads;
    std::string kernel_type;  // "dense", "csr", "csc"
    std::string implementation; // "scalar", "simd", "omp", "simd_omp"
};

// Add RooflineModel struct definition
struct RooflineModel {
    double peak_gflops;
    double memory_bandwidth_gb_s;
    double compute_roofline(double ai) const {
        return std::min(peak_gflops, memory_bandwidth_gb_s * ai);
    }
};

class BenchmarkSuite {
public:
    struct BenchmarkConfig {
        std::vector<size_t> sizes;  // Matrix sizes to test
        std::vector<float> sparsities; // Sparsity levels
        std::vector<int> thread_counts;
        int repetitions;
        bool validate;
        bool use_perf_counters;
    };
    
    static void run_comprehensive_benchmarks(const BenchmarkConfig& config);
    
    // Individual experiments
    static void experiment_correctness_validation();
    static void experiment_simd_threading_speedup();
    static void experiment_density_break_even();
    static void experiment_working_set_transitions();
    static void experiment_roofline_analysis();
    
private:
    static ExperimentResult run_dense_experiment(const ExperimentConfig& config);
    static ExperimentResult run_sparse_experiment(const ExperimentConfig& config);
    
    static void save_results_csv(const std::string& filename,
                                const std::vector<ExperimentResult>& results);
    
    static RooflineModel characterize_hardware();
    
    // Memory bandwidth measurement
    static double measure_memory_bandwidth();
    static void run_streaming_benchmark(size_t size_bytes, double& read_bw, double& write_bw);
    
    // Cache characterization
    static void characterize_cache_hierarchy();
    static size_t detect_cache_size(size_t max_size_mb = 32);
    static double measure_cache_bandwidth(size_t working_set_size);
    
    // Cache size detection results
    static size_t l1_cache_size;
    static size_t l2_cache_size; 
    static size_t l3_cache_size;
    static double measured_memory_bw;
};