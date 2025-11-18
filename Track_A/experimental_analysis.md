Explain break even using arithmetic intensity and bandwidth
The break even sparcity point of CSR SpMM being faster than Dense GEMM was at a sparcity of 0.2, or 20%. This is due to the arithmetic intensity of the higher sparcity matricies decrease in CSR SpMM, but staying somewhat constant in Dense GEMM. The lower AI also lets CSR SpMM utilize the full bandwidth of the CPU, hitting roughly 34 GFLOP/s, 7 more GFLOP/s than Dense GEMM ever saw. 

Discuss where each kernel becomes memory-bound (in roofline analysis)
The Dense GEMM kernel is always memory-bound during its runtime. Since every operation has a float to load in, only so many operations can happen at once due to the bandwidth limiting the speed of the load of the numbers.

The CSR SpMM kernel is compute bound at small matrix sizes, but memory bound at larger matrix sizes. This is due to the fact that small matricies can be loaded in with many less load steps than larger matricies, meaning the bandwidth peak is not seen. Also, as sparcity increased, the operations moved more towards the compute bound part of the graph. This is due to CSR SpMM taking advantage of multiplications with 0. Instead of having to load in every element, if the first element is 0, the solution in 0, saving the bandwidth of the CPU and moving the computation more towards the compute side of the roofline model.

Conclude compute- vs memory-bound regimes. (also in roofline analysis)
Computer vs memory bound regimes were found to have their border point at roughly 8 FLOP/byte. This was found with a realistic estimate of 100 peak GFLOP/s and an average measured bandwidth of 12.8 GB/s (seen in working_set_transitions.png).

Clear discussion of anomalies/limits and practical recommendations
anomalies:
anomaly 1:
Dense GEMM saw its worst performance in a sparcity range of 2%-5%
reason:
Dense GEMM was designed to run on dense matricies, so running matricies with less than 2% sparcity fast make sense. As sparcity rises to higher numbers, the amount of simple multiplications (containing a 0) increases, so it sees a runtime speedup above 5%.
anomaly 2:
CPNZ of 300 was recorded in single threaded Csr SpMM.
reason:
It averaged the CPNZ of multiple matrix sizes, including 64x64 matricies (idk if this is a valid explination)
anomaly 3:
small errors were seen in the implementation
reason:
generic summary of how code can be slightly unreliable on very large scales

limits:
my CPU does not run AVX-512
I was not able to run matrix sizes larger than 1024x1024, this means I was not able to test matricies stored in DRAM


recommendations:
close other programs on computer, ensure no background updates
disable CPU frequency scaling
use high performance mode 
have adequate cooling

# Performance Analysis: Dense vs Sparse Matrix Multiplication

## Break-Even Analysis Using Arithmetic Intensity and Bandwidth

The break even sparsity point where CSR SpMM becomes faster than Dense GEMM is at **20% sparsity** (0.2). This happens due to how these kernels use memory bandwidth and CPU resources:

- **Dense GEMM** maintains relatively large arithmetic intensity (~10-200 FLOP/byte across sizes, seen in roofline_analysis_dense.png) but must process all matrix elements regardless of sparsity
- **CSR SpMM** shows decreasing arithmetic intensity with higher sparsity (~10-120 FLOP/byte at low sparsity, ~1-15 FLOP/byte at high sparcity, seen in roofline_analysis_sparse.png), but avoids unnecessary computations on zero elements
- At 20% sparsity, CSR SpMM achieved roughly **27 GFLOP/s**, outperforming Dense GEMM's 26 GFLOP/s by leveraging more efficient memory bandwidth utilization. And at 50% sparsity, CSR SpMM achieved 34 GFLOP/s, far surpasing Dense GEMM's peak of 27 GFLOP/s.

## Memory-Bound vs Compute-Bound Regimes in Roofline Analysis

### Dense GEMM Characteristics
- **Consistently memory-bound** across all tested configurations
- Limited by the need to load/store all matrix elements regardless of their values
- Performance constrained by memory bandwidth rather than computational capability
- Arithmetic intensity remains relatively high

### CSR SpMM Characteristics
- **Transitional behavior**: Compute-bound at small sizes, memory-bound at larger sizes
- **Small matrices** (64x64): Fit in smaller caches, reducing memory pressure and enabling compute-bound operation
- **Large matrices** (>64x64): Exceed smaller caches' capacity, becoming memory-bound due to irregular access patterns
- **Sparsity advantage**: Higher sparsity reduces memory traffic by simplifying zeros multiplications, shifting performance toward compute-bound regime

## Compute vs Memory-Bound Boundary

The transition between compute-bound and memory-bound regimes occurs at approximately **8 FLOP/byte**, calculated as:
`Peak Performance: 100 GFLOP/s (theoretical CPU peak)
Measured Bandwidth: 12.8 GB/s (from working_set_transitions.png)
Boundary AI = 100 GFLOP/s / 12.8 GB/s = 7.8 FLOP/byte ~ 8 FLOP/byte`

## Anomalies and Performance Limits

### Anomaly 1: Dense GEMM Performance Dip at 2-5% Sparsity
**Observation**: Worst performance occurred in the 2-5% sparsity range in density_break_even.png

**Explanation**: 
At low sparsities (<2%) matrices are dense, allowing for Dense GEMM to perform on its optimal data type. At higher sparsities (>5%) increasing the number of zero multiplications, which provides a small amount of relief. However, at sparcities of 2-5%, it is a worst case scenario for Dense GEMM where ther are enough zeros to disrupt it, but not enough zeros to provide any relief.


### Anomaly 2: High CPNZ (300 cycles/non-zero) in Single-Threaded CSR SpMM
**Observation**: Unexpectedly high CPNZ in simd_threading_speedup.png

**Explanation**: 
I noticed two trends in the comprehensive data. One was that changes in sparsity level for CSR SPR resulted in relatively higher CPNZ (3-5x normal values), and the other was that larger matricies had higher CPNZs. I believe the first trend is due to the CPU having to load the entire matrix into the cache, causing a large delay that affected the CPNZ measurement (which was based off of the total time per matrix operation and then averaged). I believe the second trend is a normal result of larger matricies, and was simply amplified by the first trend. Although warm up runs were done, it seems it was not enough to offset the loading of the matricies into the cache.  

### Anomaly 3: Implementation Inconsistencies
**Observation**: Small error and performance variations in correctness_validation.md

**Explanation**:
I believe the small amount of error seen (roughly 1e-7) is a result of simple floating point error. It is a result of the approximations of floating point numbers done by languages like C++ due to limitations on the number of bits per variable. It could also be just general small error of a computer, but the amount of error seen was so neglegable that it had no influence on the end results.

## Experimental Limitations

1. **Hardware Constraints**:
   - No AVX-512 support on i5-12600KF processor
   - Limited to mainstream consumer-grade hardware

2. **Matrix Size Restrictions**:
   - Maximum tested size: 1024×1024 due to memory constraints
   - Unable to test DRAM-bound scenarios with larger matrices
   - Cache hierarchy effects limited to L1/L2/L3 boundaries

3. **Measurement Challenges**:
   - Timer resolution limitations for small matrix operations
   - Windows 11 system background process interference
   - Thermal throttling potential during extended benchmarks

## Practical Recommendations for Reproducible Benchmarking

### System Configuration
- Close background applications
- Disable unnecessary services/background updates
- Disable CPU frequency scaling
- Enable High Performance power plan
- Ensure adequate cooling


### Experimental Setup in a Perfect World
- Use larger matrix sizes (>2048×2048) to better observe DRAM effects
- Increase iteration counts for more stable timing measurements
- Implement longer warm-up phases to account for CPU boost behavior
- Consider moving to Linux for more accurate performance counters

---
