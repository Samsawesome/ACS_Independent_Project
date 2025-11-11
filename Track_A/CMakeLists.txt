cmake_minimum_required(VERSION 3.15)
project(MatrixMultiplicationBenchmark)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# Windows-specific settings
if(WIN32)
    add_definitions(-DNOMINMAX)  # Prevent Windows min/max macros
    
    if(MSVC)
        set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} /O2 /arch:AVX2 /fp:fast /openmp")
    else()
        # Assume Clang or GCC on Windows
        set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -O3 -mavx2 -mfma -ffast-math -fopenmp")
    endif()
else()
    # Linux settings
    set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -O3 -march=native -ffast-math -fopenmp")
endif()

# Find OpenMP
find_package(OpenMP)
if(OpenMP_CXX_FOUND)
    set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} ${OpenMP_CXX_FLAGS}")
endif()

# Executable
add_executable(matrix_benchmark
    src/main.cpp
    src/dense_gemm.cpp
    src/sparse_spmm.cpp
    src/matrix.cpp
    src/utils_win.cpp
    src/benchmarks.cpp
)

if(OpenMP_CXX_FOUND)
    target_link_libraries(matrix_benchmark OpenMP::OpenMP_CXX)
endif()