# Experiment 1: Correctness Validation Results

**Tolerance Threshold:** 1e-5

**Overall Pass Rate:** 100.0% (18/18)

## Implementation Error Summary

| Implementation | Mean Error | Max Error | Min Error | Overall Status |
|----------------|------------|-----------|-----------|----------------|
| omp | 3.10e-08 | 1.00e-07 | 0.00e+00 | **PASS** |
| scalar | 0.00e+00 | 0.00e+00 | 0.00e+00 | **PASS** |
| simd | 3.10e-08 | 1.00e-07 | 0.00e+00 | **PASS** |

## Detailed Test Results

| Implementation | Matrix Size | Sparsity | Max Relative Error | Status |
|----------------|-------------|----------|-------------------|--------|
| scalar | 32 | 0.0 | 0.00e+00 | PASS |
| simd | 32 | 0.0 | 8.57e-08 | PASS |
| omp | 32 | 0.0 | 8.57e-08 | PASS |
| scalar | 32 | 0.1 | 0.00e+00 | PASS |
| simd | 32 | 0.1 | 1.00e-07 | PASS |
| omp | 32 | 0.1 | 1.00e-07 | PASS |
| scalar | 64 | 0.0 | 0.00e+00 | PASS |
| simd | 64 | 0.0 | 0.00e+00 | PASS |
| omp | 64 | 0.0 | 0.00e+00 | PASS |
| scalar | 64 | 0.1 | 0.00e+00 | PASS |
| simd | 64 | 0.1 | 0.00e+00 | PASS |
| omp | 64 | 0.1 | 0.00e+00 | PASS |
| scalar | 128 | 0.0 | 0.00e+00 | PASS |
| simd | 128 | 0.0 | 0.00e+00 | PASS |
| omp | 128 | 0.0 | 0.00e+00 | PASS |
| scalar | 128 | 0.1 | 0.00e+00 | PASS |
| simd | 128 | 0.1 | 0.00e+00 | PASS |
| omp | 128 | 0.1 | 0.00e+00 | PASS |
