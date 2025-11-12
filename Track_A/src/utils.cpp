#include "utils.h"
#include <intrin.h>
#include <sstream>
#include <iomanip>
#include <iostream>
#include <cstring>

void WindowsUtils::set_high_priority() {
    SetPriorityClass(GetCurrentProcess(), HIGH_PRIORITY_CLASS);
}

void WindowsUtils::pin_thread_to_core(DWORD_PTR core_mask) {
    SetThreadAffinityMask(GetCurrentThread(), core_mask);
}

std::string WindowsUtils::get_cpu_info() {
    int cpuInfo[4] = {-1};
    char cpuBrand[0x40] = {0};
    
    // Get CPU vendor
    __cpuid(cpuInfo, 0);
    int nIds = cpuInfo[0];
    memset(cpuBrand, 0, sizeof(cpuBrand));
    
    if (nIds >= 1) {
        __cpuid(cpuInfo, 0x80000000);
        int nExIds = cpuInfo[0];
        
        // Get CPU brand string if available
        if (nExIds >= 0x80000004) {
            __cpuid(reinterpret_cast<int*>(cpuBrand), 0x80000002);
            __cpuid(reinterpret_cast<int*>(cpuBrand + 16), 0x80000003);
            __cpuid(reinterpret_cast<int*>(cpuBrand + 32), 0x80000004);
        }
    }
    
    // Get feature flags
    bool has_avx = false;
    bool has_avx2 = false;
    bool has_avx512 = false;
    
    // Check for AVX
    __cpuid(cpuInfo, 1);
    has_avx = (cpuInfo[2] & (1 << 28)) != 0;
    
    // Check for AVX2 and AVX-512
    __cpuid(cpuInfo, 7);
    has_avx2 = (cpuInfo[1] & (1 << 5)) != 0;
    has_avx512 = (cpuInfo[1] & (1 << 16)) != 0;
    
    std::stringstream ss;
    ss << cpuBrand << " | AVX: " << (has_avx ? "Yes" : "No")
       << " | AVX2: " << (has_avx2 ? "Yes" : "No")
       << " | AVX-512: " << (has_avx512 ? "Yes" : "No");
    
    return ss.str();
}

std::string WindowsUtils::get_compiler_info() {
    std::stringstream ss;
#ifdef _MSC_VER
    ss << "MSVC " << _MSC_VER;
#elif defined(__GNUC__)
    ss << "GCC " << __GNUC__ << "." << __GNUC_MINOR__ << "." << __GNUC_PATCHLEVEL__;
#elif defined(__clang__)
    ss << "Clang " << __clang_major__ << "." << __clang_minor__ << "." << __clang_patchlevel__;
#else
    ss << "Unknown compiler";
#endif
    return ss.str();
}

double WindowsUtils::get_memory_bandwidth() {
    return 50.0; // Conservative estimate in GB/s
}

size_t WindowsUtils::get_cache_size(int level) {
    switch(level) {
        case 1: return 32 * 1024;
        case 2: return 256 * 1024;
        case 3: return 12 * 1024 * 1024;
        default: return 0;
    }
}

// Windows Performance Counter implementation
WindowsUtils::PerformanceCounter::PerformanceCounter() {
    QueryPerformanceFrequency(&frequency_);
}

void WindowsUtils::PerformanceCounter::start() {
    QueryPerformanceCounter(&start_time_);
}

void WindowsUtils::PerformanceCounter::stop() {
    QueryPerformanceCounter(&end_time_);
}

double WindowsUtils::PerformanceCounter::get_elapsed_seconds() const {
    return static_cast<double>(end_time_.QuadPart - start_time_.QuadPart) / frequency_.QuadPart;
}

long long WindowsUtils::PerformanceCounter::get_cycle_count() const {
    return __rdtsc();
}

// Global utility functions
std::string get_cpu_info() {
    return WindowsUtils::get_cpu_info();
}

void setup_environment() {
    WindowsUtils::set_high_priority();
    
    #ifdef _OPENMP
    _putenv_s("OMP_PROC_BIND", "TRUE");
    _putenv_s("OMP_PLACES", "cores");
    #endif
    
    std::cout << "Environment setup complete:" << std::endl;
    std::cout << "  CPU: " << get_cpu_info() << std::endl;
    std::cout << "  Compiler: " << WindowsUtils::get_compiler_info() << std::endl;
    #ifdef _OPENMP
    std::cout << "  OpenMP: Enabled" << std::endl;
    #else
    std::cout << "  OpenMP: Disabled" << std::endl;
    #endif
}