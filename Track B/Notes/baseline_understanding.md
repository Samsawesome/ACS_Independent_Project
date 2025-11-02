Driven by NVIDIA, the industry is developing a new breed of NVMe SSD, Storage-Next SSD, targeting tens of millions of random IOPS (≈10× today’s NVMe SSDs). 
- new SSDs are being developed that are much faster than current day SSDs

These devices are designed for TB/PB-scale AI workloads dominated by random access (e.g., vector search, retrieval-augmented generation, large-scale feature stores, lowlatency data staging). 
- the reason they are being developed is mainly for AI

As Storage-Next SSDs arrive, the primary bottleneck increasingly shifts to host-side software overheads (e.g., queue submission/completion handling, checksums, and small metadata transforms). 
- because they are so fast, the bottleneck is now in the host (CPU/GPU) side

To mitigate host-path overheads, NVIDIA is developing mechanisms that let GPUs interface directly and efficiently with Storage-Next NVMe SSDs.
- to combat this, NVIDIA wants to have the GPU control the SSDs (highly parallelized)
- this is because CPU is specialized for general workload, while GPU is specialized for parallel computations
- if the SSD IOPS can become parallel computations, then they can utilize the GPU and allow the CPU to continue managing general loads

This project explores a domain-specific “IOPS core” on the host (CPU/GPU side), 
- goal is to create a IOPS core on the host (cpu/gpu) side
- we know the goal is to end up with an IOPS core on the GPU side

a lightweight, latency-deterministic engine modeled at the microarchitectural level and paired with a minimal OS/driver interface, 
- the IOPS core would optmially be lightweight (not computational complex),
- latency-determinisitc, meaning bound by the clock, not the memory bandwidth/fetches
- modeled at the microarchitectural level meaning it would be integrated into existing tech, not a new chip
- minimal OS/driver interface, meaning handle most things on the hardware side

to reduce per-I/O software overhead. 
- the goal is to reduce the software overhead of I/O's by taking more onto the hardware side (GPU)

The goal is to quantify how microarchitecture + OS-interface co-design (command queues, batching, context management) improves IOPS and p95/p99 latency for AI-centric I/O patterns vs. 
- show that IOPS core in microarch w minimal OS improved IOPS and p95/p99 latency for AI I/O data patterns

a general-purpose CPU thread or an unaccelerated firmware path. 
- compare with a general CPU thread or the other thing

Through simulation and analytical modeling, students investigate how instruction simplicity, pipeline width, and queue depth interact with software submission paths, and how those choices propagate to end-to-end I/O throughput and tail latency in AI workloads. 
- simulate and model to show how instruction simplicity, pipeline width, and queue depth interact w software and how that affects throughput and tail latency in AI data
- key word: tail latency. the goal is to minimize tail latency while still keeping OK average latency

Focus on modeling and software; RTL design and kernel development are non-goals for this project
- create the IOPS in software, model it
- RTL design aka systemverilog that shows how registers will deal with data
- kernel development aka software that acts like OS (directly affects hardware)