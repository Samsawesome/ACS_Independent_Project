@echo off
echo Matrix Multiplication Benchmark Suite for Windows (Clang)
echo.

:: Check if clang is available
clang --version >nul 2>&1
if %errorlevel% neq 0 (
    echo Error: Clang compiler not found in PATH
    echo Please install LLVM/Clang and add it to your system PATH
    pause
    exit /b 1
)

:: Create build directory
if not exist build mkdir build
cd build

echo Building project with Clang...

:: Compile all source files with Clang
clang++ -O3 -mavx2 -mfma -ffast-math -fopenmp ^
    -I../src ^
    -std=c++17 ^
    -DNOMINMAX ^
    -o matrix_benchmark.exe ^
    ../../src/main.cpp ^
    ../../src/dense_gemm.cpp ^
    ../../src/sparse_spmm.cpp ^
    ../../src/matrix.cpp ^
    ../../src/utils.cpp ^
    ../../src/benchmark.cpp

if %errorlevel% neq 0 (
    echo Compilation failed!
    cd ..
    pause
    exit /b 1
)

echo Build successful!
cd ..

echo Setting high process priority...
:: Note: This command might require admin privileges
wmic process where name="matrix_benchmark.exe" CALL setpriority "high priority" >nul 2>&1

echo.
echo Running benchmarks...
build\matrix_benchmark.exe

if %errorlevel% neq 0 (
    echo.
    echo Benchmark execution failed!
    pause
    exit /b 1
)

echo.
echo Experiments completed!
echo.
echo Generating plots...
py ..\plot_results.py

if %errorlevel% neq 0 (
    echo.
    echo Plot generation failed! Make sure Python and required packages are installed.
    echo Required packages: matplotlib, pandas, seaborn
    echo Install with: pip install matplotlib pandas seaborn
)

echo.
echo All tasks completed!
pause