#ifndef PERFORMANCE_COUNTERS_H
#define PERFORMANCE_COUNTERS_H

#include <windows.h>
#include <pdh.h>
#include <pdhmsg.h>

#pragma comment(lib, "pdh.lib")

typedef struct {
    PDH_HQUERY query;
    PDH_HCOUNTER disk_read_time;
    PDH_HCOUNTER disk_write_time;
    PDH_HCOUNTER disk_reads_sec;
    PDH_HCOUNTER disk_writes_sec;
} DISK_PERF_MONITOR;

BOOL InitializeDiskPerfMonitor(DISK_PERF_MONITOR* monitor);
BOOL GetDiskPerfStats(DISK_PERF_MONITOR* monitor, ULONGLONG* read_cycles, ULONGLONG* write_cycles);
void CloseDiskPerfMonitor(DISK_PERF_MONITOR* monitor);

#endif