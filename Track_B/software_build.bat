@echo off
echo Building Block Layer Performance Test with Clang...

echo Using Clang compiler...
clang -o block_layer_test.exe main.c performance_counters.c -lkernel32 -lpdh -lpsapi

if %errorlevel% equ 0 (
    echo Build successful!
    echo.
    echo To run the program:
    echo block_layer_test.exe
) else (
    echo Build failed!
)

pause