#include "performance_counters.h"
#include <windows.h>
#include <intrin.h>

#pragma comment(lib, "pdh.lib")

BOOL InitializeDiskPerfMonitor(DISK_PERF_MONITOR* monitor) {
    PDH_STATUS status;
    
    status = PdhOpenQuery(NULL, 0, &monitor->query);
    if (status != ERROR_SUCCESS) {
        return FALSE;
    }
    
    // Add counters for disk performance in cycles
    status = PdhAddEnglishCounterA(monitor->query,
        "\\PhysicalDisk(*)\\Avg. Disk sec/Read",
        0, &monitor->disk_read_time);
    
    status = PdhAddEnglishCounterA(monitor->query,
        "\\PhysicalDisk(*)\\Avg. Disk sec/Write",
        0, &monitor->disk_write_time);
    
    status = PdhAddEnglishCounterA(monitor->query,
        "\\PhysicalDisk(*)\\Disk Reads/sec",
        0, &monitor->disk_reads_sec);
    
    status = PdhAddEnglishCounterA(monitor->query,
        "\\PhysicalDisk(*)\\Disk Writes/sec",
        0, &monitor->disk_writes_sec);
    
    return (status == ERROR_SUCCESS);
}

BOOL GetDiskPerfStats(DISK_PERF_MONITOR* monitor, ULONGLONG* read_cycles, ULONGLONG* write_cycles) {
    PDH_STATUS status;
    PDH_FMT_COUNTERVALUE counter_value;
    double cpu_frequency_ghz = 3.9; // Adjust to your CPU
    
    status = PdhCollectQueryData(monitor->query);
    if (status != ERROR_SUCCESS) {
        return FALSE;
    }
    
    // Get read time and convert to cycles
    status = PdhGetFormattedCounterValue(monitor->disk_read_time, 
                                        PDH_FMT_DOUBLE, NULL, &counter_value);
    if (status == ERROR_SUCCESS && counter_value.doubleValue > 0) {
        // Convert seconds to cycles
        *read_cycles = (ULONGLONG)(counter_value.doubleValue * cpu_frequency_ghz * 1e9);
    }
    
    // Get write time and convert to cycles
    status = PdhGetFormattedCounterValue(monitor->disk_write_time, 
                                        PDH_FMT_DOUBLE, NULL, &counter_value);
    if (status == ERROR_SUCCESS && counter_value.doubleValue > 0) {
        // Convert seconds to cycles
        *write_cycles = (ULONGLONG)(counter_value.doubleValue * cpu_frequency_ghz * 1e9);
    }
    
    return (status == ERROR_SUCCESS);
}

void CloseDiskPerfMonitor(DISK_PERF_MONITOR* monitor) {
    if (monitor->query) {
        PdhCloseQuery(monitor->query);
        monitor->query = NULL;
    }
}