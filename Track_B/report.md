# Hardware Analysis Report

## 1. Overview

This report analyzes the performance of the hardware only Windows I/O stack program (implemented in SystemVerilog with a 100 MHz clock, and simulated in ModelSim) with a fully serialized NVMe command execution path.  
Unlike the previous version one, the parallel-capable design, or a real computer, this implementation processes one NVMe command at a time, drastically limiting throughput and increasing latency.  
The following analysis serves to quantify the impact of this serialization.

**Key Specifications:**
- Clock frequency: 100 MHz (1 cycle = 10 ns)
- Workload: 70 mixed read/write commands (40 reads, 30 writes), total 471,040 bytes
- Internal NVMe command execution: serialized
- Measured SSD raw-access latency: 5000 cycles (50 us)

While a real SSD would have slight variations in latency, the simulated SSD in this project was given a consistent latency so that the analysis of the output numbers of the program would not be influenced by potential random noise from the different variations in the latency of the SSD

---

## 2. Key Performance Indicators

| Metric                         | Value             |
|--------------------------------|-------------------|
| **Commands Processed**         | 70                |
| **Total Simulation Time**      | 3,510,345 ns (3.51 ms) |
| **Total Clock Cycles**         | 351,023           |
| **IOPS**                       | 19,941            |
| **Average Throughput**         | 0.13 GB/s (134 MB/s) |
| **System Efficiency**          | 0.26%             |
| **Average Latency**            | 176,151 cycles (1.76 ms) |
| **95th Percentile Latency**    | 332,391 cycles (3.32 ms) |
| **99th Percentile Latency**    | 342,311 cycles (3.42 ms) |
| **SSD Component (minimum)**    | 5,000 cycles (50 us) |

*Efficiency defined as actual bytes/cycle vs. ideal 64‑byte data‑bus peak at 100 MHz (6.4 GB/s).*

---

## 3. Detailed Performance Analysis

### 3.1 Command Throughput and Bus Utilization

- **Throughput**: 70 commands in 3.51 ms ⇒ **19,941 IOPS**  
  This closely matches the theoretical maximum of a single SSD with 50 us access time:  
  `1 / 50 us = 20,000 IOPS`.  
  The accelerator is limited and saturated by the SSD latency; commands can only be processed every 50 us.

- **Data bandwidth**: 471,040 bytes in 3.51 ms ⇒ **134.2 MB/s**.  
  The peak bandwidth of this bus at 100 MHz is **6.4 GB/s**.  
  The observed throughput uses only **2.1% of the raw bus capacity**. The **system efficiency** of 0.26% shows just how bad the under‑utilization is.

- **Average cycles per command** (based on total cycles): 351,023 / 70 = **5,014.6 cycles** (50.15 us). This is nearly identical to the 5,000‑cycle SSD latency, which confirms that the issue purely stems from the serial nature of the program and the latency of the SSD.

### 3.2 Latency Breakdown & Queuing

While the command issue rate is one per 50 us, the **end‑to‑end latency** experienced by an individual command is dramatically higher.

| Latency Component          | Cycles       | Time (us)   |
|----------------------------|--------------|-------------|
| Minimum observed           | 5,031        | 50.31       |
| SSD raw‑access (given)     | 5,000        | 50.00       |
| **Average total latency**  | **176,151**  | **1,761.51**|
| **P99 total latency**      | **342,311**  | **3,423.11**|

- The difference between average latency and the SSD minimum shows that there is a large **queuing delay**. This is a classic giveaway of a serial bus.  
- Using Little’s Law:  
  `Average Queue Depth = IOPS × Average Latency`  
  = 19,941 s⁻¹ × 1.7615×10⁻³ s ≈ **35.1 commands**.  
  This means, on average, 35 commands are waiting in the system while one is being serviced by the SSD. The serial execution creates a backlog because commands arrive faster than the single server can process them. Although, upon encountering a larger workload, the amount of commands waiting in the system would directly increase with the number of commands. Assuming n commands, the amount waiting on average would be n/2. This pattern can be seen with the smaller data set used as well, since 70/3 is roughly equal to 35.1.

- The **P99 latency** is nearly twice the average, indicating severe tail‑latency amplification once again due to the serial nature of the program.

### 3.3 Analysis of the Impact of Serialized NVMe Execution

As repeatedly stated earlier, the core bottleneck and flow of this program is the serial command processing implemented in the NVMe subsystem.  
- This serialization **prevents overlapped I/O** – the hardware cannot hide SSD latency by issuing multiple concurrent reads/writes. Consequently, IOPS is capped at 1/(SSD_access_time) = 20,000.

Version one of this project (a less accurate translation) has a parallel hardware implementation, which lets it achieve **4.4 M IOPS** and **7.52 us average latency** with the same 100 MHz clock. This is purely due to the program exploiting NVMe’s parallelism. This serialized design loses over **99.5% of that potential IOPS** and increases average latency by a factor of **234×**.

### 3.4 Latency Distribution & Predictability

- **Minimum latency:** 5,031 cycles (≈50.3 us) – command with minimal queuing, almost purely SSD overhead.  
- **Maximum latency:** 347,271 cycles (≈3.47 ms) – ~70× the minimum.  
- The **P95/P99 spread** (332k to 342k cycles) is very narrow, indicating that once a queue builds up, all commands suffer similar long waits. This fits with the observed behaviors of a serial bus.
- **Latency variability** is essentially constant due to the queue occupancy at arrival time. This makes the tail behavior a direct consequence of the serial bottleneck and SSD latency.

### 3.5 Graphical Analysis

Just so that there were visual to look at, graphs were generated to compare the current new serial project with the old less accurate parallelized project. They can be see in the Figures directory, and are the images that do not end with DEPRICATED. Essentially every graph shows one of two things: 0 improvement from the new software to the old software, or much larger latency / smaller throughput / smaller IOPS. The figures, in my opinion, do not help with the understanding of the performance of this project nearly as much as this report's explination does, and that is why all of the graphs are essentially meaningless.

---

## 4. Root‑Cause Analysis: Serialization

**Why the performance is so poor:**

1. **The bus is a serial bus** – Essentially every single issue this program faces stems from the fact that the bus was not able to be implemented in parallel. The above data has shown how badly this affected the latency and throughput of the commands in this project, and all of the flaws of a serial bus have been highlighted and repeated many times. Let this be an exercise in the poor performance of NVMe (a system designed to exploit the characteristics of a parallel bus) when implemented in series. 


**Comparison with a parallel baseline**  
If the design were parallelized (e.g., using multiple NVMe submission queues and overlapping DMA transfers), the same hardware could potentially achieve:

- Basically the same IOPS (assuming that no techniques were used to improve the response time of the SSD)
- Latency that gets close to matching the SSD access time (≈50 us).  
- Bus efficiency well above 50%, as the program would become SSD bound (throughput bound).

For a purely theoretical estimate of the potential of this program, see the data in Outputs/hardware_output-DEPRICATED.txt. While the numbers in that file would most likely be impossible to achieve in a real world implementation, they stand as a good example of what the theoretical limits of this program would be.

---

## 5. Conclusion

- The serialized NVMe hardware accelerator delivers only **19,941 IOPS and 1.76 ms average latency**, a far cry from its maximum efficiency.  
- **The primary cause** is the forced serialization of all NVMe commands, which caps IOPS at 1/SSD_latency and creates large queuing delays.  
- **Efficiency is negligible** (0.26% of peak bus bandwidth), showing that the hardware’s raw resources are almost completely wasted.  
- This result **validates the critical need for parallel command processing** in hardware storage accelerators, and shows how even a well optimized program can fail under one critical and slow bottleneck.

**Recommendation:** Future iterations must implement:
- A parallel bus
Future iterations should also implement some of the following:
- An accurate queue used for a completion queue instead of a modelel queue
- Further optimizations to increase speed of the program
- Different ratios of read/write commands
- Potentially a different type of I/O technique, such as direct I/O using something similar to SPDK

## 6. My final personal note

My personal opinion and ending statement for this project is that it was not a waste of time, even if the data makes it seem like a complete failure. A large amount of time and effort was put into getting all of the different moving parts to work together, and also to clean the code so that it only implements what is necessary to implement. I still learned a lot from this independent project even if the strict results from the output statistics show that negative progress was made. The current code rewrote essentially the entire original project, along with adding many new modules to fully accurately simulate how the Windows I/O stack functions. If the two programs of the serial bus and the incomplete completion queue are removed, this project was a huge success. Other than the wait for the SSD, read/write commands were able to go from being issued to being given to the SSD in under 10 clock cycles. Comparing this to a current time of ~100 cycles for a command to get from the CPU to the SQ for the SSD and this program suddenly seems very promising. Overall, I learned a lot from this project and consider it a success even if the pure data does not show that.


