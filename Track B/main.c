#define _CRT_SECURE_NO_WARNINGS
#include <windows.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <psapi.h>
#include <tchar.h>
#include <intrin.h>

#define BLOCK_SIZE 4096
#define MAX_COMMANDS 1000
#define FILE_SIZE (1024 * 1024 * 1024) // 1GB test file
#define ITERATIONS 1000  // Run multiple iterations for better timing

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
    DWORD io_count;
    ULONGLONG total_bytes;
} PERFORMANCE_STATS;

// Global variables
IO_COMMAND commands[MAX_COMMANDS];
int command_count = 0;
HANDLE test_file = INVALID_HANDLE_VALUE;
char* test_buffer = NULL;
PERFORMANCE_STATS stats = {0};
double cpu_frequency_ghz = 3.9; // 3.9 GHz

// Function prototypes
BOOL ReadCommandsFromFile(const char* filename);
BOOL CreateTestFile(const char* filename);
void CloseTestFile();
void RunCommandsSoftware();
void RunSingleCommand(IO_COMMAND* cmd, ULONGLONG* kernel_cycles, ULONGLONG* user_cycles);
ULONGLONG GetCurrentCycleCount();
ULONGLONG MeasureSystemCallOverhead();
void PrintStatistics();
void Cleanup();

// Helper function to convert FILETIME to ULONGLONG
ULONGLONG FileTimeToULongLong(FILETIME ft) {
    return ((ULONGLONG)ft.dwHighDateTime << 32) | ft.dwLowDateTime;
}

int main() {
    printf("Windows Block Layer Performance Measurement\n");
    printf("CPU Frequency: %.1f GHz\n", cpu_frequency_ghz);
    printf("==========================================\n\n");

    // Measure system call overhead first
    ULONGLONG syscall_overhead = MeasureSystemCallOverhead();
    printf("System call overhead: %llu cycles\n", syscall_overhead);

    // Initialize
    if (!ReadCommandsFromFile("cpu_commands.txt")) {
        printf("Error: Failed to read commands file\n");
        return 1;
    }

    printf("Read %d commands from file\n", command_count);

    // Create test file
    if (!CreateTestFile("test_file.bin")) {
        printf("Error: Failed to create test file\n");
        return 1;
    }

    // Allocate buffer for I/O
    test_buffer = (char*)VirtualAlloc(NULL, BLOCK_SIZE * 1024, 
                                     MEM_COMMIT | MEM_RESERVE, 
                                     PAGE_READWRITE);
    if (!test_buffer) {
        printf("Error: Failed to allocate buffer\n");
        Cleanup();
        return 1;
    }

    // Initialize buffer with test data
    memset(test_buffer, 0xAA, BLOCK_SIZE * 1024);

    // Run commands and measure performance
    printf("\nStarting software block layer simulation...\n");
    printf("Running %d iterations for better timing accuracy...\n", ITERATIONS);
    RunCommandsSoftware();

    // Print results
    PrintStatistics();

    Cleanup();
    return 0;
}

BOOL ReadCommandsFromFile(const char* filename) {
    FILE* file = fopen(filename, "r");
    if (!file) {
        printf("Error: Cannot open file %s\n", filename);
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
        
        printf("Read command: op=%d, lba=%lld, len=%lu, data=0x%llX\n", 
               commands[command_count].opcode,
               commands[command_count].lba,
               commands[command_count].length,
               commands[command_count].data);
        
        command_count++;
    }

    fclose(file);
    
    if (command_count == 0) {
        printf("Warning: No commands were successfully read from the file");
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
        printf("Error: CreateFile failed (%lu)\n", GetLastError());
        return FALSE;
    }

    // Set file size
    LARGE_INTEGER file_size;
    file_size.QuadPart = FILE_SIZE;
    if (!SetFilePointerEx(test_file, file_size, NULL, FILE_BEGIN) ||
        !SetEndOfFile(test_file)) {
        printf("Error: SetFilePointer/SetEndOfFile failed (%lu)\n", GetLastError());
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
    // Measure the overhead of a simple system call
    ULONGLONG start, end;
    FILETIME creation, exit, kernel, user;
    
    start = GetCurrentCycleCount();
    GetProcessTimes(GetCurrentProcess(), &creation, &exit, &kernel, &user);
    end = GetCurrentCycleCount();
    
    return end - start;
}

void RunCommandsSoftware() {
    ULONGLONG total_start_cycles = GetCurrentCycleCount();
    
    // Run multiple iterations for better timing accuracy
    for (int iter = 0; iter < ITERATIONS; iter++) {
        for (int i = 0; i < command_count; i++) {
            ULONGLONG kernel_cycles = 0;
            ULONGLONG user_cycles = 0;
            
            RunSingleCommand(&commands[i], &kernel_cycles, &user_cycles);
            
            stats.kernel_cycles += kernel_cycles;
            stats.user_cycles += user_cycles;
            stats.io_count++;
            stats.total_bytes += commands[i].length;
        }
    }
    
    ULONGLONG total_end_cycles = GetCurrentCycleCount();
    stats.total_cycles = total_end_cycles - total_start_cycles;
}

void RunSingleCommand(IO_COMMAND* cmd, ULONGLONG* kernel_cycles, ULONGLONG* user_cycles) {
    LARGE_INTEGER file_offset;
    DWORD bytes_processed;
    BOOL result;
    FILETIME start_creation, start_exit, start_kernel, start_user;
    FILETIME end_creation, end_exit, end_kernel, end_user;
    ULONGLONG start_cycles, end_cycles;
    
    // Get process times before command
    if (!GetProcessTimes(GetCurrentProcess(), &start_creation, &start_exit, 
                        &start_kernel, &start_user)) {
        printf("Error: Failed to get process times\n");
        return;
    }
    
    start_cycles = GetCurrentCycleCount();
    
    // Calculate file offset (LBA is byte-based in our simulation)
    file_offset.QuadPart = cmd->lba;

    // Set file pointer
    if (!SetFilePointerEx(test_file, file_offset, NULL, FILE_BEGIN)) {
        printf("Error: SetFilePointerEx failed for command %d (%lu)\n", 
               cmd->opcode, GetLastError());
        return;
    }

    // Execute read or write operation
    if (cmd->opcode == 0) { // Read operation
        result = ReadFile(test_file, test_buffer, cmd->length, 
                         &bytes_processed, NULL);
        
        if (!result) {
            printf("Error: ReadFile failed at LBA %lld (%lu)\n", 
                   cmd->lba, GetLastError());
        } else if (ITERATIONS == 1) { // Only print for single iteration
            printf("Read %lu bytes from LBA %lld\n", 
                   bytes_processed, cmd->lba);
        }
    } else { // Write operation
        // Prepare write data (using the data field from command)
        memset(test_buffer, (BYTE)(cmd->data & 0xFF), cmd->length);
        
        result = WriteFile(test_file, test_buffer, cmd->length, 
                          &bytes_processed, NULL);
        
        if (!result) {
            printf("Error: WriteFile failed at LBA %lld (%lu)\n", 
                   cmd->lba, GetLastError());
        } else if (ITERATIONS == 1) { // Only print for single iteration
            printf("Wrote %lu bytes to LBA %lld\n", 
                   bytes_processed, cmd->lba);
        }
    }

    // Force writes to disk if this was a write operation
    if (cmd->opcode == 1) {
        FlushFileBuffers(test_file);
    }
    
    end_cycles = GetCurrentCycleCount();
    
    // Get process times after command
    if (!GetProcessTimes(GetCurrentProcess(), &end_creation, &end_exit, 
                        &end_kernel, &end_user)) {
        printf("Error: Failed to get process times\n");
        return;
    }
    
    // Calculate kernel and user time in cycles
    ULONGLONG kernel_time_100ns = FileTimeToULongLong(end_kernel) - FileTimeToULongLong(start_kernel);
    ULONGLONG user_time_100ns = FileTimeToULongLong(end_user) - FileTimeToULongLong(start_user);
    ULONGLONG total_time_cycles = end_cycles - start_cycles;
    
    // Convert 100ns intervals to cycles (approximate)
    // 100ns = 100 * 10^-9 seconds, cycles = time * frequency
    double cycles_per_100ns = cpu_frequency_ghz * 100; // 3.9 GHz * 100 = 390 cycles per 100ns
    
    *kernel_cycles = (ULONGLONG)(kernel_time_100ns * cycles_per_100ns);
    *user_cycles = (ULONGLONG)(user_time_100ns * cycles_per_100ns);
}

void PrintStatistics() {
    printf("\n=== BLOCK LAYER PERFORMANCE RESULTS ===\n");
    printf("Total iterations: %d\n", ITERATIONS);
    printf("Total commands processed: %lu\n", stats.io_count);
    
    // Convert cycles to time
    double total_time_seconds = (double)stats.total_cycles / (cpu_frequency_ghz * 1e9);
    double avg_time_per_command_ms = (total_time_seconds * 1000.0) / stats.io_count;
    
    printf("Total I/O time: %.2f milliseconds\n", total_time_seconds * 1000.0);
    printf("Average time per command: %.2f microseconds\n", avg_time_per_command_ms * 1000.0);
    
    // Calculate percentages
    ULONGLONG total_cpu_cycles = stats.kernel_cycles + stats.user_cycles;
    
    printf("\nCPU Cycle Breakdown:\n");
    printf("Kernel cycles (block layer): %llu (%.1f%%)\n", 
           stats.kernel_cycles, 
           total_cpu_cycles > 0 ? (double)stats.kernel_cycles / total_cpu_cycles * 100.0 : 0);
    printf("User cycles: %llu (%.1f%%)\n", 
           stats.user_cycles,
           total_cpu_cycles > 0 ? (double)stats.user_cycles / total_cpu_cycles * 100.0 : 0);
    printf("Total CPU cycles: %llu\n", total_cpu_cycles);
    
    // Calculate efficiency metrics
    double total_data_mb = (double)stats.total_bytes / (1024.0 * 1024.0);
    double total_time_sec = total_time_seconds;
    double data_rate_mbps = total_data_mb / total_time_sec;
    
    printf("\nThroughput: %.2f MB/s\n", data_rate_mbps);
    
    double blocks_processed = (double)stats.total_bytes / BLOCK_SIZE;
    if (blocks_processed > 0) {
        double kernel_cycles_per_block = (double)stats.kernel_cycles / blocks_processed;
        printf("Kernel overhead per 4KB block: %.0f cycles (%.2f microseconds)\n", 
               kernel_cycles_per_block,
               kernel_cycles_per_block / (cpu_frequency_ghz * 1000.0));
    }
    
    // Compare with hardware IO chip (estimated)
    printf("\n=== HARDWARE IO CHIP ESTIMATION ===\n");
    printf("Estimated hardware overhead: 100-500 cycles per command\n");
    printf("Potential speedup: %.1fx - %.1fx\n", 
           (double)stats.kernel_cycles / stats.io_count / 500.0,
           (double)stats.kernel_cycles / stats.io_count / 100.0);
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
    
    // Delete test file
    DeleteFileA("test_file.bin");
}