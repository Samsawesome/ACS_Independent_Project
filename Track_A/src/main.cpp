#include "benchmark.h"
#include "utils.h"
#include <iostream>
#include <cstdlib>

int main(int argc, char* argv[]) {
    std::cout << "Dense vs Sparse Matrix Multiplication Benchmark Suite\n";
    
    // Setup environment
    setup_environment();
    
    BenchmarkSuite::BenchmarkConfig config;
    
    // Matrix sizes: square cases
    config.sizes = {64, 128, 256, 512, 1024};
    
    // Sparsity sweep
    config.sparsities = {0.001f, 0.005f, 0.01f, 0.02f, 0.05f, 0.1f, 0.2f, 0.5f};
    
    // Thread counts
    config.thread_counts = {1, 2, 4, 8, 16};
    config.repetitions = 3;
    config.validate = true;
    config.use_perf_counters = false;
    
    // Run individual experiments
    std::cout << "\nRunning Experiment 1: Correctness Validation\n";
    BenchmarkSuite::experiment_correctness_validation();
    
    std::cout << "\nRunning Experiment 2: SIMD & Threading Speedup\n";
    BenchmarkSuite::experiment_simd_threading_speedup();
    
    std::cout << "\nRunning Experiment 3: Density Break-even Analysis\n";
    BenchmarkSuite::experiment_density_break_even();
    
    std::cout << "\nRunning Experiment 4: Working Set Transitions\n";
    BenchmarkSuite::experiment_working_set_transitions();
    
    std::cout << "\nRunning Experiment 5: Roofline Analysis\n";
    BenchmarkSuite::experiment_roofline_analysis();
    
    // Run comprehensive benchmarks
    std::cout << "\nRunning Comprehensive Benchmarks\n";
    BenchmarkSuite::run_comprehensive_benchmarks(config);
    
    return 0;
}