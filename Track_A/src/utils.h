#pragma once
#include <windows.h>
#include <vector>
#include <string>

class WindowsUtils {
public:
    static void set_high_priority();
    static void pin_thread_to_core(DWORD_PTR core_mask);
    static std::string get_cpu_info();
    static std::string get_compiler_info();
    static double get_memory_bandwidth(); // Theoretical peak for analysis
    static size_t get_cache_size(int level); // L1, L2, L3 cache sizes
    
    // Windows performance counters
    class PerformanceCounter {
    public:
        PerformanceCounter();
        ~PerformanceCounter() = default;
        void start();
        void stop();
        double get_elapsed_seconds() const;
        long long get_cycle_count() const;
        
    private:
        LARGE_INTEGER frequency_;
        LARGE_INTEGER start_time_;
        LARGE_INTEGER end_time_;
    };
};

// Global utility functions for main.cpp
std::string get_cpu_info();
void setup_environment();