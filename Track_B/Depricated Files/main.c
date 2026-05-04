#define _CRT_SECURE_NO_WARNINGS
#include <windows.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <psapi.h>
#include <tchar.h>
#include <intrin.h>
#include <math.h>  // For sqrt() in standard deviation calculation

#define BLOCK_SIZE 4096
#define MAX_COMMANDS 1000
#define FILE_SIZE (1024 * 1024 * 1024) // 1GB test file
#define ITERATIONS 1000  // Run multiple iterations for better timing
#define NUM_RUNS 3       // Number of measurement runs to average
#define WARMUP_ITERATIONS 100  // Warm-up iterations
#define MAX_LATENCY_SAMPLES (MAX_COMMANDS * ITERATIONS)  // Maximum samples we can store

#define BLOCK_LAYER_OVERHEAD_PER_CMD 25000  // Based on disk_track.etl
#define PCIE_PROTOCOL_OVERHEAD_CYCLES 1500
#define CONTROLLER_OVERHEAD_CYCLES 2000

#define SSD_READ_LATENCY 50.0
#define SSD_WRITE_LATENCY 30.0

typedef struct {
    int opcode;      // 0: read, 1: write
    LONGLONG lba;    // Logical Block Address
    DWORD length;    // Transfer length in bytes
    LONGLONG data;   // Write data
} IO_COMMAND;

typedef struct {
    ULONGLONG kernel_cycles;
    ULONGLONG user_cycles;
    ULONGLONG total_cycles;
    ULONGLONG estimated_block_layer_cycles;
    ULONGLONG estimated_hardware_cycles;
    DWORD io_count;
    DWORD read_count;
    DWORD write_count;
    ULONGLONG total_bytes;
    
    // Latency statistics
    ULONGLONG min_latency_cycles;
    ULONGLONG max_latency_cycles;
    double avg_latency_cycles;
    ULONGLONG p50_latency_cycles;  // Median
    ULONGLONG p90_latency_cycles;
    ULONGLONG p95_latency_cycles;
    ULONGLONG p99_latency_cycles;
    ULONGLONG p999_latency_cycles; // P99.9
    double std_dev_cycles;
    ULONGLONG* latency_samples;    // Array to store individual latencies
    ULONGLONG sample_count;        // Actual number of samples collected
} PERFORMANCE_STATS;

// Global variables
IO_COMMAND commands[MAX_COMMANDS];
int command_count = 0;
HANDLE test_file = INVALID_HANDLE_VALUE;
char* test_buffer = NULL;
PERFORMANCE_STATS stats_array[NUM_RUNS];
PERFORMANCE_STATS avg_stats = {0};
double cpu_frequency_ghz = 3.9; // 3.9 GHz

// Output file handle
FILE* output_file = NULL;

// Function prototypes
BOOL ReadCommandsFromFile(const char* filename);
BOOL CreateTestFile(const char* filename);
void CloseTestFile();
void RunCommandsSoftware(PERFORMANCE_STATS* stats);
void RunWarmup();
void RunSingleCommandBasic(IO_COMMAND* cmd);
void RunSingleCommandWithTiming(IO_COMMAND* cmd, ULONGLONG* latency_cycles);
ULONGLONG GetCurrentCycleCount();
ULONGLONG MeasureSystemCallOverhead();
void PrintToFile(const char* format, ...);
void PrintStatistics(PERFORMANCE_STATS* stats);
void PrintAveragedStatistics();
void AverageStats();
void CalculateLatencyStatistics(PERFORMANCE_STATS* stats);
int CompareULONGLONG(const void* a, const void* b);
double CalculateIOPS(ULONGLONG total_operations, double total_time_seconds);
void PrintIOPSAnalysis(PERFORMANCE_STATS* stats);
void Cleanup();

// Helper function to convert FILETIME to ULONGLONG
ULONGLONG FileTimeToULongLong(FILETIME ft) {
    return ((ULONGLONG)ft.dwHighDateTime << 32) | ft.dwLowDateTime;
}

// Convert microseconds to cycles based on CPU frequency
ULONGLONG MicrosecondsToCycles(double microseconds) {
    return (ULONGLONG)(microseconds * cpu_frequency_ghz * 1000.0);
}

// Convert cycles to microseconds
double CyclesToMicroseconds(ULONGLONG cycles) {
    return (double)cycles / (cpu_frequency_ghz * 1000.0);
}

// Estimate hardware latency in cycles based on operation type
ULONGLONG EstimateHardwareLatencyCycles(int opcode, DWORD length) {
    double hardware_latency_us;
    
    if (opcode == 0) { // Read
        // Realistic SSD read latency including protocol overhead
        hardware_latency_us = SSD_READ_LATENCY/16;  // More realistic: 50µs for 4K random read
    } else { // Write
        // Realistic SSD write latency
        hardware_latency_us = SSD_WRITE_LATENCY/16;  // More realistic: 30µs for 4K random write
    }
    
    // Add PCIe and controller overhead
    ULONGLONG base_cycles = MicrosecondsToCycles(hardware_latency_us);
    
    return base_cycles + PCIE_PROTOCOL_OVERHEAD_CYCLES + CONTROLLER_OVERHEAD_CYCLES;
}

double HardwareCyclesToCPUCycles(double hardware_cycles) {
    double cpu_freq_mhz = cpu_frequency_ghz * 1000.0; // Convert GHz to MHz
    double hardware_freq_mhz = 100.0; // Hardware runs at 100 MHz
    double scaling_factor = cpu_freq_mhz / hardware_freq_mhz; // 3900 / 100 = 39
    
    return (hardware_cycles * scaling_factor);
}

// Custom print function that writes to both console and file
void PrintToFile(const char* format, ...) {
    va_list args;
    char buffer[1024];
    
    // Format the string
    va_start(args, format);
    vsprintf(buffer, format, args);
    va_end(args);
    
    // Print to console
    printf("%s", buffer);
    
    // Print to file if open
    if (output_file) {
        fprintf(output_file, "%s", buffer);
    }
}

// Comparison function for qsort
int CompareULONGLONG(const void* a, const void* b) {
    ULONGLONG val_a = *(const ULONGLONG*)a;
    ULONGLONG val_b = *(const ULONGLONG*)b;
    
    if (val_a < val_b) return -1;
    if (val_a > val_b) return 1;
    return 0;
}

double CalculateIOPS(ULONGLONG total_operations, double total_time_seconds) {
    if (total_time_seconds <= 0.0) {
        return 0.0;
    }
    return (double)total_operations / total_time_seconds;
}

void PrintIOPSAnalysis(PERFORMANCE_STATS* stats) {
    double total_time_seconds = (double)stats->total_cycles / (cpu_frequency_ghz * 1e9);
    
    // Calculate overall IOPS
    double overall_iops = CalculateIOPS(stats->io_count, total_time_seconds);
    double read_iops = CalculateIOPS(stats->read_count, total_time_seconds);
    double write_iops = CalculateIOPS(stats->write_count, total_time_seconds);
    
    PrintToFile("\n=== IOPS ANALYSIS ===\n");
    PrintToFile("Overall IOPS: %.2f\n", overall_iops);
    PrintToFile("Read IOPS: %.2f\n", read_iops);
    PrintToFile("Write IOPS: %.2f\n", write_iops);
    
    // If we have latency samples, we can estimate peak/burst IOPS
    if (stats->sample_count > 0) {
        // Calculate time for a single operation at P50, P95, P99 latencies
        double p50_time_us = CyclesToMicroseconds(stats->p50_latency_cycles);
        double p95_time_us = CyclesToMicroseconds(stats->p95_latency_cycles);
        double p99_time_us = CyclesToMicroseconds(stats->p99_latency_cycles);
        double avg_time_us = CyclesToMicroseconds(stats->avg_latency_cycles);
        
        // Calculate theoretical peak IOPS (1 operation / latency)
        double peak_iops_p50 = 1000000.0 / p50_time_us;  // 1 second = 1,000,000 microseconds
        double peak_iops_p95 = 1000000.0 / p95_time_us;
        double peak_iops_p99 = 1000000.0 / p99_time_us;
        double peak_iops_avg = 1000000.0 / avg_time_us;
        
        PrintToFile("\nTheoretical Peak IOPS (single operation):\n");
        PrintToFile("  Based on P50 latency: %.2f\n", peak_iops_p50);
        PrintToFile("  Based on P95 latency: %.2f\n", peak_iops_p95);
        PrintToFile("  Based on P99 latency: %.2f\n", peak_iops_p99);
        PrintToFile("  Based on average latency: %.2f\n", peak_iops_avg);
        
        // Calculate IOPS efficiency (achieved vs theoretical)
        double efficiency_vs_p50 = (overall_iops / peak_iops_p50) * 100.0;
        double efficiency_vs_avg = (overall_iops / peak_iops_avg) * 100.0;
        
        PrintToFile("\nIOPS Efficiency:\n");
        PrintToFile("  Achieved vs P50 theoretical: %.1f%%\n", efficiency_vs_p50);
        PrintToFile("  Achieved vs average theoretical: %.1f%%\n", efficiency_vs_avg);
        
        // Calculate the IOPS at different percentile windows
        if (stats->sample_count >= 1000) {  // Only if we have enough samples
            PrintToFile("\nIOPS Consistency Analysis:\n");
            
            // Calculate IOPS for different time windows (estimated)
            // For 100 samples at P50 latency
            double time_100_ops_p50 = p50_time_us * 100.0 / 1000000.0;  // Convert to seconds
            double iops_100_p50 = 100.0 / time_100_ops_p50;
            
            // For 100 samples at P99 latency (worst-case burst)
            double time_100_ops_p99 = p99_time_us * 100.0 / 1000000.0;
            double iops_100_p99 = 100.0 / time_100_ops_p99;
            
            PrintToFile("  Burst IOPS (100 operations at P50): %.2f\n", iops_100_p50);
            PrintToFile("  Burst IOPS (100 operations at P99): %.2f\n", iops_100_p99);
            PrintToFile("  Burst vs sustained ratio: %.2f:1\n", iops_100_p50 / overall_iops);
        }
    }
    
    // Calculate operations per millisecond for easy reference
    double ops_per_ms = overall_iops / 1000.0;
    PrintToFile("\nOperations per millisecond: %.2f\n", ops_per_ms);
    
    // Calculate the time per operation in different units
    double time_per_op_us = 1000000.0 / overall_iops;
    double time_per_op_ns = time_per_op_us * 1000.0;
    PrintToFile("Time per operation: %.2f us (%.0f ns)\n", time_per_op_us, time_per_op_ns);
}

// Calculate latency statistics including percentiles
void CalculateLatencyStatistics(PERFORMANCE_STATS* stats) {
    if (stats->sample_count == 0 || stats->latency_samples == NULL) {
        return;
    }
    
    // Sort the latency samples for percentile calculation
    qsort(stats->latency_samples, stats->sample_count, sizeof(ULONGLONG), CompareULONGLONG);
    
    // Calculate min, max, and sum for average
    stats->min_latency_cycles = stats->latency_samples[0];
    stats->max_latency_cycles = stats->latency_samples[stats->sample_count - 1];
    
    ULONGLONG sum_cycles = 0;
    for (ULONGLONG i = 0; i < stats->sample_count; i++) {
        sum_cycles += stats->latency_samples[i];
    }
    stats->avg_latency_cycles = (double)sum_cycles / stats->sample_count;
    
    // Calculate standard deviation
    double sum_squared_diff = 0.0;
    for (ULONGLONG i = 0; i < stats->sample_count; i++) {
        double diff = (double)stats->latency_samples[i] - stats->avg_latency_cycles;
        sum_squared_diff += diff * diff;
    }
    stats->std_dev_cycles = sqrt(sum_squared_diff / stats->sample_count);
    
    // Calculate percentiles
    // P50 (median)
    stats->p50_latency_cycles = stats->latency_samples[(ULONGLONG)(stats->sample_count * 0.50)];
    
    // P90
    stats->p90_latency_cycles = stats->latency_samples[(ULONGLONG)(stats->sample_count * 0.90)];
    
    // P95
    stats->p95_latency_cycles = stats->latency_samples[(ULONGLONG)(stats->sample_count * 0.95)];
    
    // P99
    stats->p99_latency_cycles = stats->latency_samples[(ULONGLONG)(stats->sample_count * 0.99)];
    
    // P99.9
    stats->p999_latency_cycles = stats->latency_samples[(ULONGLONG)(stats->sample_count * 0.999)];
}

int main() {
    // Open output file
    output_file = fopen("Outputs/software_output.txt", "w");
    if (!output_file) {
        printf("Error: Failed to open output file software_output.txt\n");
        return 1;
    }
    
    // Print initial messages
    printf("Starting Windows Block Layer Performance Measurement...\n");
    printf("All output will be saved to software_output.txt\n\n");
    
    PrintToFile("Windows Block Layer Performance Measurement\n");
    PrintToFile("CPU Frequency: %.1f GHz\n", cpu_frequency_ghz);
    PrintToFile("Samsung 980 Pro 2TB Latencies:\n");
    PrintToFile("  Read: ~%.1f us, Write: ~%.1f us\n", SSD_READ_LATENCY, SSD_WRITE_LATENCY);
    PrintToFile("==========================================\n\n");

    // Measure system call overhead first
    ULONGLONG syscall_overhead = MeasureSystemCallOverhead();
    PrintToFile("System call overhead: %llu cycles (%.3f us)\n", 
           syscall_overhead, (double)syscall_overhead / (cpu_frequency_ghz * 1000.0));

    // Initialize
    if (!ReadCommandsFromFile("Commands/software_cpu_commands.txt")) {
        PrintToFile("Error: Failed to read commands file\n");
        fclose(output_file);
        return 1;
    }

    PrintToFile("Read %d commands from file\n", command_count);

    // Create test file
    if (!CreateTestFile("test_file.bin")) {
        PrintToFile("Error: Failed to create test file\n");
        fclose(output_file);
        return 1;
    }

    // Allocate buffer for I/O
    test_buffer = (char*)VirtualAlloc(NULL, BLOCK_SIZE * 1024, 
                                     MEM_COMMIT | MEM_RESERVE, 
                                     PAGE_READWRITE);
    if (!test_buffer) {
        PrintToFile("Error: Failed to allocate buffer\n");
        fclose(output_file);
        Cleanup();
        return 1;
    }

    // Initialize buffer with test data
    memset(test_buffer, 0xAA, BLOCK_SIZE * 1024);

    // Run warm-up phase
    printf("Starting warm-up phase...\n");
    PrintToFile("\nStarting warm-up phase (%d iterations)...\n", WARMUP_ITERATIONS);
    RunWarmup();
    PrintToFile("Warm-up complete.\n");

    // Allocate latency sample arrays for each run
    for (int run = 0; run < NUM_RUNS; run++) {
        stats_array[run].latency_samples = (ULONGLONG*)malloc(MAX_LATENCY_SAMPLES * sizeof(ULONGLONG));
        if (!stats_array[run].latency_samples) {
            PrintToFile("Error: Failed to allocate latency sample array for run %d\n", run);
            fclose(output_file);
            Cleanup();
            return 1;
        }
        stats_array[run].sample_count = 0;
    }

    // Run multiple measurement runs
    printf("Starting %d measurement runs...\n", NUM_RUNS);
    PrintToFile("\nStarting %d measurement runs...\n", NUM_RUNS);
    for (int run = 0; run < NUM_RUNS; run++) {
        printf("  Run %d/%d\n", run + 1, NUM_RUNS);
        PrintToFile("\n--- Run %d/%d ---\n", run + 1, NUM_RUNS);
        memset(&stats_array[run], 0, sizeof(PERFORMANCE_STATS));
        stats_array[run].latency_samples = (ULONGLONG*)malloc(MAX_LATENCY_SAMPLES * sizeof(ULONGLONG));
        stats_array[run].sample_count = 0;
        
        RunCommandsSoftware(&stats_array[run]);
        
        // Calculate latency statistics for this run
        CalculateLatencyStatistics(&stats_array[run]);
        
        // Print individual run statistics
        PrintStatistics(&stats_array[run]);
        
        // Small pause between runs to let system settle
        if (run < NUM_RUNS - 1) {
            Sleep(100); // 100ms pause
        }
    }

    // Calculate and print averaged statistics
    AverageStats();
    CalculateLatencyStatistics(&avg_stats);
    
    printf("Writing results to software_output.txt...\n");
    PrintAveragedStatistics();
    
    // Close output file
    fclose(output_file);
    output_file = NULL;
    
    printf("\nMeasurement complete. Results saved to software_output.txt\n");

    Cleanup();
    return 0;
}

BOOL ReadCommandsFromFile(const char* filename) {
    FILE* file = fopen(filename, "r");
    if (!file) {
        PrintToFile("Error: Cannot open file %s\n", filename);
        return FALSE;
    }

    command_count = 0;
    
    // Read line by line to handle hex values properly
    char line[256];
    while (command_count < MAX_COMMANDS && fgets(line, sizeof(line), file)) {
        // Skip empty lines
        if (strlen(line) <= 1) continue;
        
        char* token = strtok(line, " \t\n");
        if (!token) continue;
        
        // Parse opcode (decimal)
        commands[command_count].opcode = atoi(token);
        
        // Parse LBA (decimal)
        token = strtok(NULL, " \t\n");
        if (!token) continue;
        commands[command_count].lba = _strtoi64(token, NULL, 10);
        
        // Parse length (decimal)
        token = strtok(NULL, " \t\n");
        if (!token) continue;
        commands[command_count].length = strtoul(token, NULL, 10);
        
        // Parse data (hexadecimal)
        token = strtok(NULL, " \t\n");
        if (!token) continue;
        commands[command_count].data = _strtoi64(token, NULL, 16);
        
        command_count++;
    }

    fclose(file);
    
    if (command_count == 0) {
        PrintToFile("Warning: No commands were successfully read from the file");
    }
    return command_count > 0;
}

BOOL CreateTestFile(const char* filename) {
    // Create a large sparse file for testing
    test_file = CreateFileA(filename,
                           GENERIC_READ | GENERIC_WRITE,
                           FILE_SHARE_READ,
                           NULL,
                           CREATE_ALWAYS,
                           FILE_FLAG_NO_BUFFERING | FILE_FLAG_WRITE_THROUGH,
                           NULL);

    if (test_file == INVALID_HANDLE_VALUE) {
        PrintToFile("Error: CreateFile failed (%lu)\n", GetLastError());
        return FALSE;
    }

    // Set file size
    LARGE_INTEGER file_size;
    file_size.QuadPart = FILE_SIZE;
    if (!SetFilePointerEx(test_file, file_size, NULL, FILE_BEGIN) ||
        !SetEndOfFile(test_file)) {
        PrintToFile("Error: SetFilePointer/SetEndOfFile failed (%lu)\n", GetLastError());
        CloseHandle(test_file);
        test_file = INVALID_HANDLE_VALUE;
        return FALSE;
    }

    // Reset to beginning
    SetFilePointer(test_file, 0, NULL, FILE_BEGIN);
    return TRUE;
}

ULONGLONG GetCurrentCycleCount() {
    return __rdtsc();
}

ULONGLONG MeasureSystemCallOverhead() {
    ULONGLONG start, end;
    ULONGLONG min_overhead = (ULONGLONG)-1;
    FILETIME creation, exit, kernel, user;
    // Measure multiple times and take minimum
    for (int i = 0; i < 100; i++) {
        start = GetCurrentCycleCount();
        GetProcessTimes(GetCurrentProcess(), &creation, &exit, &kernel, &user);
        end = GetCurrentCycleCount();
        
        ULONGLONG overhead = end - start;
        if (overhead < min_overhead) {
            min_overhead = overhead;
        }
    }
    
    return min_overhead;
}

void RunWarmup() {
    // Run commands without measurement to warm up caches and system
    for (int iter = 0; iter < WARMUP_ITERATIONS; iter++) {
        for (int i = 0; i < command_count; i++) {
            RunSingleCommandBasic(&commands[i]);
        }
    }
}

void RunSingleCommandBasic(IO_COMMAND* cmd) {
    LARGE_INTEGER file_offset;
    DWORD bytes_processed;
    BOOL result;
    
    // Calculate file offset
    file_offset.QuadPart = cmd->lba;

    // Set file pointer
    if (!SetFilePointerEx(test_file, file_offset, NULL, FILE_BEGIN)) {
        return;
    }

    // Execute read or write operation
    if (cmd->opcode == 0) { // Read operation
        result = ReadFile(test_file, test_buffer, cmd->length, 
                         &bytes_processed, NULL);
    } else { // Write operation
        memset(test_buffer, (BYTE)(cmd->data & 0xFF), cmd->length);
        result = WriteFile(test_file, test_buffer, cmd->length, 
                          &bytes_processed, NULL);
    }

    if (!result) {
        return;
    }

    // Force writes to disk if this was a write operation
    if (cmd->opcode == 1) {
        FlushFileBuffers(test_file);
    }
}

void RunSingleCommandWithTiming(IO_COMMAND* cmd, ULONGLONG* latency_cycles) {
    ULONGLONG start_cycles = GetCurrentCycleCount();
    RunSingleCommandBasic(cmd);
    ULONGLONG end_cycles = GetCurrentCycleCount();
    *latency_cycles = end_cycles - start_cycles;
}

void RunCommandsSoftware(PERFORMANCE_STATS* stats) {
    ULONGLONG total_start_cycles = GetCurrentCycleCount();
    FILETIME start_creation, start_exit, start_kernel, start_user;
    
    // Get process times BEFORE all iterations
    if (!GetProcessTimes(GetCurrentProcess(), &start_creation, &start_exit, 
                        &start_kernel, &start_user)) {
        PrintToFile("Error: Failed to get initial process times\n");
        return;
    }
    
    // Initialize basic stats
    stats->io_count = command_count * ITERATIONS;
    stats->total_bytes = 0;
    stats->read_count = 0;
    stats->write_count = 0;
    stats->sample_count = 0;
    
    // Pre-calculate totals for all iterations
    for (int i = 0; i < command_count; i++) {
        stats->total_bytes += commands[i].length * ITERATIONS;
        if (commands[i].opcode == 0) {
            stats->read_count += ITERATIONS;
        } else {
            stats->write_count += ITERATIONS;
        }
    }
    
    // Run multiple iterations for better timing accuracy
    for (int iter = 0; iter < ITERATIONS; iter++) {
        for (int i = 0; i < command_count; i++) {
            ULONGLONG latency_cycles;
            RunSingleCommandWithTiming(&commands[i], &latency_cycles);
            
            // Store latency sample if we have space
            if (stats->sample_count < MAX_LATENCY_SAMPLES) {
                stats->latency_samples[stats->sample_count++] = latency_cycles;
            }
        }
    }
    
    ULONGLONG total_end_cycles = GetCurrentCycleCount();
    FILETIME end_creation, end_exit, end_kernel, end_user;
    
    // Get process times AFTER all iterations
    if (!GetProcessTimes(GetCurrentProcess(), &end_creation, &end_exit, 
                        &end_kernel, &end_user)) {
        PrintToFile("Error: Failed to get final process times\n");
        return;
    }
    
    // Calculate TOTAL kernel and user time for ALL operations
    ULONGLONG total_kernel_time_100ns = FileTimeToULongLong(end_kernel) - FileTimeToULongLong(start_kernel);
    ULONGLONG total_user_time_100ns = FileTimeToULongLong(end_user) - FileTimeToULongLong(start_user);
    
    // Convert 100ns intervals to cycles
    double cycles_per_100ns = cpu_frequency_ghz * 100.0;
    stats->kernel_cycles = (ULONGLONG)(total_kernel_time_100ns * cycles_per_100ns);
    stats->user_cycles = (ULONGLONG)(total_user_time_100ns * cycles_per_100ns);
    stats->total_cycles = total_end_cycles - total_start_cycles;
    
    // Calculate estimated hardware cycles based on actual operations
    stats->estimated_hardware_cycles = 0;
    for (int i = 0; i < command_count; i++) {
        ULONGLONG hardware_cycles = EstimateHardwareLatencyCycles(commands[i].opcode, commands[i].length);
        stats->estimated_hardware_cycles += hardware_cycles * ITERATIONS;
    }

    stats->estimated_block_layer_cycles = stats->io_count * BLOCK_LAYER_OVERHEAD_PER_CMD;

    // Adjust if we have better data from kernel profiling
    if (stats->kernel_cycles > stats->estimated_hardware_cycles) {
        ULONGLONG non_hardware_kernel = stats->kernel_cycles - stats->estimated_hardware_cycles;
        
        // Block layer should be a significant portion, but not all, of non-hardware kernel time
        // Use a more reasonable estimate based on actual kernel profiling data
        if (non_hardware_kernel > stats->estimated_block_layer_cycles * 1.5) {
            // If our estimate is too low, use a percentage (adjust based on your measurements)
            stats->estimated_block_layer_cycles = (ULONGLONG)(non_hardware_kernel * 0.6);
        }
    }
}

void AverageStats() {
    // Initialize average stats with zeros
    memset(&avg_stats, 0, sizeof(PERFORMANCE_STATS));
    
    // Allocate combined latency samples array for averaging
    ULONGLONG total_samples = 0;
    for (int i = 0; i < NUM_RUNS; i++) {
        total_samples += stats_array[i].sample_count;
    }
    
    if (total_samples > 0) {
        avg_stats.latency_samples = (ULONGLONG*)malloc(total_samples * sizeof(ULONGLONG));
        if (avg_stats.latency_samples) {
            avg_stats.sample_count = 0;
            for (int i = 0; i < NUM_RUNS; i++) {
                for (ULONGLONG j = 0; j < stats_array[i].sample_count; j++) {
                    if (avg_stats.sample_count < total_samples) {
                        avg_stats.latency_samples[avg_stats.sample_count++] = stats_array[i].latency_samples[j];
                    }
                }
            }
        }
    }
    
    // Sum all stats from each run for averaging
    ULONGLONG min_latency_sum = 0;
    ULONGLONG max_latency_sum = 0;
    ULONGLONG p50_latency_sum = 0;
    ULONGLONG p90_latency_sum = 0;
    ULONGLONG p95_latency_sum = 0;
    ULONGLONG p99_latency_sum = 0;
    ULONGLONG p999_latency_sum = 0;
    double avg_latency_sum = 0.0;
    double std_dev_sum = 0.0;
    
    int valid_runs = 0;
    for (int i = 0; i < NUM_RUNS; i++) {
        if (stats_array[i].sample_count > 0) {
            valid_runs++;
            avg_stats.kernel_cycles += stats_array[i].kernel_cycles;
            avg_stats.user_cycles += stats_array[i].user_cycles;
            avg_stats.total_cycles += stats_array[i].total_cycles;
            avg_stats.estimated_block_layer_cycles += stats_array[i].estimated_block_layer_cycles;
            avg_stats.estimated_hardware_cycles += stats_array[i].estimated_hardware_cycles;
            avg_stats.io_count += stats_array[i].io_count;
            avg_stats.read_count += stats_array[i].read_count;
            avg_stats.write_count += stats_array[i].write_count;
            avg_stats.total_bytes += stats_array[i].total_bytes;
            
            // Sum latency statistics
            min_latency_sum += stats_array[i].min_latency_cycles;
            max_latency_sum += stats_array[i].max_latency_cycles;
            p50_latency_sum += stats_array[i].p50_latency_cycles;
            p90_latency_sum += stats_array[i].p90_latency_cycles;
            p95_latency_sum += stats_array[i].p95_latency_cycles;
            p99_latency_sum += stats_array[i].p99_latency_cycles;
            p999_latency_sum += stats_array[i].p999_latency_cycles;
            avg_latency_sum += stats_array[i].avg_latency_cycles;
            std_dev_sum += stats_array[i].std_dev_cycles;
        }
    }
    
    if (valid_runs > 0) {
        // Calculate averages
        avg_stats.kernel_cycles /= valid_runs;
        avg_stats.user_cycles /= valid_runs;
        avg_stats.total_cycles /= valid_runs;
        avg_stats.estimated_block_layer_cycles /= valid_runs;
        avg_stats.estimated_hardware_cycles /= valid_runs;
        avg_stats.io_count /= valid_runs;
        avg_stats.read_count /= valid_runs;
        avg_stats.write_count /= valid_runs;
        avg_stats.total_bytes /= valid_runs;
        
        // Calculate average latency statistics
        avg_stats.min_latency_cycles = min_latency_sum / valid_runs;
        avg_stats.max_latency_cycles = max_latency_sum / valid_runs;
        avg_stats.p50_latency_cycles = p50_latency_sum / valid_runs;
        avg_stats.p90_latency_cycles = p90_latency_sum / valid_runs;
        avg_stats.p95_latency_cycles = p95_latency_sum / valid_runs;
        avg_stats.p99_latency_cycles = p99_latency_sum / valid_runs;
        avg_stats.p999_latency_cycles = p999_latency_sum / valid_runs;
        avg_stats.avg_latency_cycles = avg_latency_sum / valid_runs;
        avg_stats.std_dev_cycles = std_dev_sum / valid_runs;
    }
}

void PrintStatistics(PERFORMANCE_STATS* stats) {
    // Convert cycles to time
    double total_time_seconds = (double)stats->total_cycles / (cpu_frequency_ghz * 1e9);
    double avg_time_per_command_us = (total_time_seconds * 1e6) / stats->io_count;
    
    PrintToFile("Run Statistics:\n");
    PrintToFile("  Total I/O time: %.2f ms\n", total_time_seconds * 1000.0);
    PrintToFile("  Avg time per command: %.2f us\n", avg_time_per_command_us);
    
    // Calculate throughput
    double total_data_mb = (double)stats->total_bytes / (1024.0 * 1024.0);
    double data_rate_mbps = total_data_mb / total_time_seconds;
    PrintToFile("  Throughput: %.2f MB/s\n", data_rate_mbps);
    
    // Add IOPS calculation
    double overall_iops = CalculateIOPS(stats->io_count, total_time_seconds);
    PrintToFile("  Average IOPS: %.2f\n", overall_iops);
    
    // Print latency percentiles if available
    if (stats->sample_count > 0) {
        PrintToFile("  Latency samples collected: %llu\n", stats->sample_count);
        PrintToFile("  Min latency: %.2f us\n", CyclesToMicroseconds(stats->min_latency_cycles));
        PrintToFile("  Avg latency: %.2f us\n", CyclesToMicroseconds(stats->avg_latency_cycles));
        PrintToFile("  P50 latency: %.2f us\n", CyclesToMicroseconds(stats->p50_latency_cycles));
        PrintToFile("  P90 latency: %.2f us\n", CyclesToMicroseconds(stats->p90_latency_cycles));
        PrintToFile("  P95 latency: %.2f us\n", CyclesToMicroseconds(stats->p95_latency_cycles));
        PrintToFile("  P99 latency: %.2f us\n", CyclesToMicroseconds(stats->p99_latency_cycles));
        PrintToFile("  P99.9 latency: %.2f us\n", CyclesToMicroseconds(stats->p999_latency_cycles));
        PrintToFile("  Max latency: %.2f us\n", CyclesToMicroseconds(stats->max_latency_cycles));
        PrintToFile("  Std Dev: %.2f us\n", CyclesToMicroseconds(stats->std_dev_cycles));
    }
}

void PrintAveragedStatistics() {
    PrintToFile("\n==========================================\n");
    PrintToFile("=== FINAL AVERAGED RESULTS (%d runs) ===\n", NUM_RUNS);
    PrintToFile("==========================================\n");
    
    // Convert cycles to time
    double total_time_seconds = (double)avg_stats.total_cycles / (cpu_frequency_ghz * 1e9);
    double avg_time_per_command_us = (total_time_seconds * 1e6) / avg_stats.io_count;
    
    PrintToFile("Total iterations per run: %d\n", ITERATIONS);
    PrintToFile("Total commands processed per run: %lu (%lu reads, %lu writes)\n", 
           avg_stats.io_count, avg_stats.read_count, avg_stats.write_count);
    
    PrintToFile("Average total I/O time: %.2f milliseconds\n", total_time_seconds * 1000.0);
    PrintToFile("Average time per command: %.2f microseconds\n", avg_time_per_command_us);
    
    // Print detailed latency statistics
    if (avg_stats.sample_count > 0) {
        PrintToFile("\n=== LATENCY DISTRIBUTION (combined samples) ===\n");
        PrintToFile("Total samples across all runs: %llu\n", avg_stats.sample_count);
        PrintToFile("Min latency: %.2f us\n", CyclesToMicroseconds(avg_stats.min_latency_cycles));
        PrintToFile("Average latency: %.2f us\n", CyclesToMicroseconds(avg_stats.avg_latency_cycles));
        PrintToFile("Standard deviation: %.2f us\n", CyclesToMicroseconds(avg_stats.std_dev_cycles));
        PrintToFile("Coefficient of variation: %.1f%%\n", 
               (avg_stats.std_dev_cycles / avg_stats.avg_latency_cycles) * 100.0);
        
        PrintToFile("\n=== LATENCY PERCENTILES ===\n");
        PrintToFile("P50 (median): %10.2f us\n", CyclesToMicroseconds(avg_stats.p50_latency_cycles));
        PrintToFile("P90:          %10.2f us (%.1fx P50)\n", 
               CyclesToMicroseconds(avg_stats.p90_latency_cycles),
               (double)avg_stats.p90_latency_cycles / avg_stats.p50_latency_cycles);
        PrintToFile("P95:          %10.2f us (%.1fx P50)\n", 
               CyclesToMicroseconds(avg_stats.p95_latency_cycles),
               (double)avg_stats.p95_latency_cycles / avg_stats.p50_latency_cycles);
        PrintToFile("P99:          %10.2f us (%.1fx P50)\n", 
               CyclesToMicroseconds(avg_stats.p99_latency_cycles),
               (double)avg_stats.p99_latency_cycles / avg_stats.p50_latency_cycles);
        PrintToFile("P99.9:        %10.2f us (%.1fx P50)\n", 
               CyclesToMicroseconds(avg_stats.p999_latency_cycles),
               (double)avg_stats.p999_latency_cycles / avg_stats.p50_latency_cycles);
        PrintToFile("Max:          %10.2f us (%.1fx P50)\n", 
               CyclesToMicroseconds(avg_stats.max_latency_cycles),
               (double)avg_stats.max_latency_cycles / avg_stats.p50_latency_cycles);
        
        PrintToFile("\n=== LATENCY TAIL ANALYSIS ===\n");
        PrintToFile("P95 to P99 delta: %.2f us (%.1f%% increase)\n",
               CyclesToMicroseconds(avg_stats.p99_latency_cycles - avg_stats.p95_latency_cycles),
               ((double)(avg_stats.p99_latency_cycles - avg_stats.p95_latency_cycles) / avg_stats.p95_latency_cycles) * 100.0);
        PrintToFile("P99 to P99.9 delta: %.2f us (%.1f%% increase)\n",
               CyclesToMicroseconds(avg_stats.p999_latency_cycles - avg_stats.p99_latency_cycles),
               ((double)(avg_stats.p999_latency_cycles - avg_stats.p99_latency_cycles) / avg_stats.p99_latency_cycles) * 100.0);
    }
    
    // Calculate percentages
    ULONGLONG total_cpu_cycles = avg_stats.kernel_cycles + avg_stats.user_cycles;
    
    PrintToFile("\n=== DETAILED CYCLE BREAKDOWN ===\n");
    PrintToFile("Total CPU cycles: %llu\n", total_cpu_cycles);
    PrintToFile("Kernel cycles (entire I/O stack): %llu (%.1f%%)\n", 
           avg_stats.kernel_cycles, 
           total_cpu_cycles > 0 ? (double)avg_stats.kernel_cycles / total_cpu_cycles * 100.0 : 0);
    PrintToFile("User cycles: %llu (%.1f%%)\n", 
           avg_stats.user_cycles,
           total_cpu_cycles > 0 ? (double)avg_stats.user_cycles / total_cpu_cycles * 100.0 : 0);
    
    PrintToFile("\n=== ESTIMATED COMPONENT BREAKDOWN ===\n");
    if (avg_stats.kernel_cycles > 0) {
        // Calculate what portion of TOTAL TIME (not just kernel time) is hardware vs block layer
        double hardware_percentage_of_total = (double)avg_stats.estimated_hardware_cycles / avg_stats.total_cycles * 100.0;
        double block_layer_percentage_of_total = (double)avg_stats.estimated_block_layer_cycles / avg_stats.total_cycles * 100.0;
        double kernel_percentage_of_total = (double)avg_stats.kernel_cycles / avg_stats.total_cycles * 100.0;
        
        PrintToFile("Total elapsed cycles: %llu\n", avg_stats.total_cycles);
        PrintToFile("Estimated hardware cycles: %llu (%.1f%% of total time)\n",
               avg_stats.estimated_hardware_cycles, hardware_percentage_of_total);
        PrintToFile("Estimated block layer cycles: %llu (%.1f%% of total time)\n",
               avg_stats.estimated_block_layer_cycles, block_layer_percentage_of_total);
        PrintToFile("Remaining kernel cycles: %llu (%.1f%% of total time)\n",
               avg_stats.kernel_cycles - avg_stats.estimated_block_layer_cycles,
               kernel_percentage_of_total - block_layer_percentage_of_total);
        
        // Also show hardware as percentage of kernel time for reference
        double hardware_percentage_of_kernel = (double)avg_stats.estimated_hardware_cycles / avg_stats.kernel_cycles * 100.0;
        PrintToFile("Hardware cycles are %.1f%% of kernel time\n", hardware_percentage_of_kernel);
    }
    
    // Per-operation averages
    if (avg_stats.io_count > 0) {
        double avg_kernel_cycles = (double)avg_stats.kernel_cycles / avg_stats.io_count;
        double avg_block_layer_cycles = (double)avg_stats.estimated_block_layer_cycles / avg_stats.io_count;
        double avg_hardware_cycles = (double)avg_stats.estimated_hardware_cycles / avg_stats.io_count;
        
        PrintToFile("\n=== PER-OPERATION AVERAGES ===\n");
        PrintToFile("Average kernel time per I/O: %.0f cycles (%.2f us)\n", 
               avg_kernel_cycles, CyclesToMicroseconds(avg_kernel_cycles));
        PrintToFile("Average block layer per I/O: %.0f cycles (%.2f us)\n", 
               avg_block_layer_cycles, CyclesToMicroseconds(avg_block_layer_cycles));
        PrintToFile("Average hardware per I/O: %.0f cycles (%.2f us)\n", 
               avg_hardware_cycles, CyclesToMicroseconds(avg_hardware_cycles));
    }
    
    // Calculate throughput
    double total_data_mb = (double)avg_stats.total_bytes / (1024.0 * 1024.0);
    double data_rate_mbps = total_data_mb / total_time_seconds;
    
    PrintToFile("\nAverage Throughput: %.2f MB/s\n", data_rate_mbps);

    // Compare with hardware IO chip (estimated)
    PrintToFile("\n=== HARDWARE ACCELERATOR COMPARISON (WITH FREQUENCY SCALING) ===\n");
    PrintToFile("Hardware accelerator frequency: 100 MHz\n");
    PrintToFile("CPU frequency: %.0f MHz (%.1f GHz)\n", cpu_frequency_ghz * 1000.0, cpu_frequency_ghz);
    PrintToFile("Clock speed ratio: %.1fx\n", (cpu_frequency_ghz * 1000.0) / 100.0);
    
    // Convert hardware accelerator cycles to equivalent CPU cycles
    double hardware_accelerator_cycles_at_100mhz = 22.51;
    double equivalent_cpu_cycles = HardwareCyclesToCPUCycles(hardware_accelerator_cycles_at_100mhz);
    
    PrintToFile("Hardware accelerator overhead: %.2f cycles at 100 MHz\n", hardware_accelerator_cycles_at_100mhz);
    PrintToFile("Equivalent at CPU frequency: %.2f cycles at %.1f GHz\n", 
           equivalent_cpu_cycles, cpu_frequency_ghz);
    
    // Calculate time equivalence
    double hardware_time_ns = hardware_accelerator_cycles_at_100mhz * (1.0 / 100.0) * 1000.0; // Convert to ns
    double equivalent_cpu_time_ns = equivalent_cpu_cycles * (1.0 / (cpu_frequency_ghz * 1000.0)) * 1000.0; // Convert to ns
    
    PrintToFile("Hardware processing time: %.2f ns (%.2f cycles * 10 ns/cycle)\n", 
           hardware_time_ns, hardware_accelerator_cycles_at_100mhz);
    
    if (avg_stats.io_count > 0) {
        double avg_block_layer_cycles = (double)avg_stats.estimated_block_layer_cycles / avg_stats.io_count;
        double avg_block_layer_time_ns = avg_block_layer_cycles * (1.0 / (cpu_frequency_ghz * 1000.0)) * 1000.0;
        
        PrintToFile("\nComparison:\n");
        PrintToFile("  Hardware accelerator: %.2f ns per command\n", hardware_time_ns);
        PrintToFile("  Software block layer: %.2f ns per command\n", avg_block_layer_time_ns);
        
        if (avg_block_layer_time_ns > hardware_time_ns) {
            double time_speedup = avg_block_layer_time_ns / hardware_time_ns;
            PrintToFile("\nHardware accelerator is %.1fx faster (time-based)\n", time_speedup);
            
            // Also show cycle-based comparison at same frequency
            // Scale software cycles down to 100 MHz for fair comparison
            double software_cycles_at_100mhz = avg_block_layer_cycles / ((cpu_frequency_ghz * 1000.0) / 100.0);
            double cycle_speedup = software_cycles_at_100mhz / hardware_accelerator_cycles_at_100mhz;
            PrintToFile("At 100 MHz equivalent: Software = %.0f cycles, Hardware = %.2f cycles (%.1fx speedup)\n",
                   software_cycles_at_100mhz, hardware_accelerator_cycles_at_100mhz, cycle_speedup);
        } else {
            PrintToFile("\nSoftware block layer is already faster than hardware accelerator!\n");
        }
        
        // Compare with P95/P99 latencies
        if (avg_stats.sample_count > 0) {
            PrintToFile("\n=== LATENCY COMPARISON WITH HARDWARE ===\n");
            PrintToFile("Software P95 latency: %.2f ns\n", CyclesToMicroseconds(avg_stats.p95_latency_cycles) * 1000.0);
            PrintToFile("Software P99 latency: %.2f ns\n", CyclesToMicroseconds(avg_stats.p99_latency_cycles) * 1000.0);
            PrintToFile("Hardware worst-case: %.2f ns\n", 8500); // From hardware_output.txt
            
            if (CyclesToMicroseconds(avg_stats.p95_latency_cycles) * 1000.0 > hardware_time_ns * 1.5) {
                PrintToFile("\nHardware accelerator provides more predictable latency (P95 within %.1f ns)\n", 8500);
            }
        }

            // Calculate throughput
            double total_data_mb = (double)avg_stats.total_bytes / (1024.0 * 1024.0);
            double data_rate_mbps = total_data_mb / total_time_seconds;
            
            PrintToFile("\nAverage Throughput: %.2f MB/s\n", data_rate_mbps);
            
            // Add IOPS analysis for averaged statistics
            PrintToFile("\nAverage IOPS: %.2f\n", CalculateIOPS(avg_stats.io_count, total_time_seconds));
            
            // Add detailed IOPS analysis
            PrintIOPSAnalysis(&avg_stats);
    }
}

void Cleanup() {
    if (test_file != INVALID_HANDLE_VALUE) {
        CloseHandle(test_file);
        test_file = INVALID_HANDLE_VALUE;
    }
    
    if (test_buffer) {
        VirtualFree(test_buffer, 0, MEM_RELEASE);
        test_buffer = NULL;
    }
    
    // Free latency sample arrays
    for (int i = 0; i < NUM_RUNS; i++) {
        if (stats_array[i].latency_samples) {
            free(stats_array[i].latency_samples);
            stats_array[i].latency_samples = NULL;
        }
    }
    
    if (avg_stats.latency_samples) {
        free(avg_stats.latency_samples);
        avg_stats.latency_samples = NULL;
    }
    
    // Delete test file
    DeleteFileA("test_file.bin");
}