#include <windows.h>
#include <stdio.h>
#include <traceloggingprovider.h>

TRACELOGGING_DEFINE_PROVIDER(
    g_ioProvider,
    "CustomIOProvider",
    (0x3d790e56, 0x8654, 0x4c4b, 0x92, 0x8a, 0xfa, 0x77, 0x3f, 0x8c, 0x5e, 0x7d)
);

void PerformIOOperations() {
    HANDLE hFile;
    DWORD bytesRead, bytesWritten;
    CHAR buffer[64 * 1024];  // 64KB buffer
    CHAR writeBuffer[64 * 1024];
    LARGE_INTEGER fileSize, offset;
    BOOL result;
    DWORD i;
    LARGE_INTEGER startTime, endTime, frequency;
    
    QueryPerformanceFrequency(&frequency);
    
    printf("Starting I/O operations...\n");
    
    // Initialize write buffer
    for (i = 0; i < sizeof(writeBuffer); i++) {
        writeBuffer[i] = (CHAR)(i % 256);
    }
    
    // Create test file
    hFile = CreateFileA(
        "io_test_file.bin",
        GENERIC_READ | GENERIC_WRITE,
        FILE_SHARE_READ,
        NULL,
        CREATE_ALWAYS,
        FILE_ATTRIBUTE_NORMAL | FILE_FLAG_NO_BUFFERING,
        NULL
    );
    
    if (hFile == INVALID_HANDLE_VALUE) {
        printf("Error creating test file: %lu\n", GetLastError());
        return;
    }
    
    // Set file size to 2MB
    fileSize.QuadPart = 2 * 1024 * 1024;
    result = SetFilePointerEx(hFile, fileSize, NULL, FILE_BEGIN);
    result = SetEndOfFile(hFile);
    
    printf("Performing writes...\n");
    
    // Perform sequential writes with timing
    offset.QuadPart = 0;
    for (i = 0; i < 16; i++) {
        QueryPerformanceCounter(&startTime);
        
        result = SetFilePointerEx(hFile, offset, NULL, FILE_BEGIN);
        if (!result) {
            printf("SetFilePointerEx failed: %lu\n", GetLastError());
            break;
        }
        
        result = WriteFile(hFile, writeBuffer, sizeof(writeBuffer), &bytesWritten, NULL);
        if (!result || bytesWritten != sizeof(writeBuffer)) {
            printf("WriteFile failed: %lu\n", GetLastError());
            break;
        }
        
        // Force write to disk
        FlushFileBuffers(hFile);
        
        QueryPerformanceCounter(&endTime);
        
        double writeTime = (double)(endTime.QuadPart - startTime.QuadPart) / frequency.QuadPart * 1000.0;
        
        printf("Write %lu: %lu bytes in %.2f ms\n", i, bytesWritten, writeTime);
        
        offset.QuadPart += sizeof(writeBuffer);
    }
    
    printf("Performing reads...\n");
    
    // Perform sequential reads with timing
    offset.QuadPart = 0;
    for (i = 0; i < 16; i++) {
        QueryPerformanceCounter(&startTime);
        
        result = SetFilePointerEx(hFile, offset, NULL, FILE_BEGIN);
        if (!result) {
            printf("SetFilePointerEx failed: %lu\n", GetLastError());
            break;
        }
        
        result = ReadFile(hFile, buffer, sizeof(buffer), &bytesRead, NULL);
        if (!result || bytesRead != sizeof(buffer)) {
            printf("ReadFile failed: %lu\n", GetLastError());
            break;
        }
        
        QueryPerformanceCounter(&endTime);
        
        double readTime = (double)(endTime.QuadPart - startTime.QuadPart) / frequency.QuadPart * 1000.0;
        
        printf("Read %lu: %lu bytes in %.2f ms\n", i, bytesRead, readTime);
        
        offset.QuadPart += sizeof(buffer);
    }
    
    CloseHandle(hFile);
    DeleteFileA("io_test_file.bin");
    
    printf("I/O operations completed.\n");
}

int main() {
    // Initialize ETW provider
    TraceLoggingRegister(g_ioProvider);
    
    printf("=== Enhanced I/O Tracer ===\n");
    
    // Log start event
    TraceLoggingWrite(g_ioProvider, "IOWorkloadStart");
    
    PerformIOOperations();
    
    // Log end event
    TraceLoggingWrite(g_ioProvider, "IOWorkloadEnd");
    
    TraceLoggingUnregister(g_ioProvider);
    
    printf("Workload complete. Check ETW trace for details.\n");
    return 0;
}