the goal is to create a custom chip (system verilog) that can handle a large amount of IOPS
IOPS are how many read/writes can be processed in a second
chip must be optimized for reads and writes, and only reads or writes
read/write commands go through NVMe which has specifications on what the command contains
since I am just doing read and writes, my commands can be simple
1 byte command (read/write), 7 bytes address
this way it is a 64-bit command

the goal is to run as many reads/writes as possible
the reads/writes are random access so there is no locality
this means an internal cache may be unnecesary
but also we will recieve a page (4KB) of memory at once that must be rooted through

writes go to the SSD which handles essentially the entire write
reads go to the core (CPU/GPU) and are essentially output

the goal is to take software overheads
(e.g., vector search, retrieval-augmented generation, large-scale feature stores, low-latency data staging)
and to have them be handled on the hardware side (can be parallelized, etc)

The goal is to quantify how microarchitecture + OS-interface co-design
(command queues, batching, context management) improves IOPS and p95/p99 latency for AI-centric I/O
patterns vs. a general-purpose CPU thread or an unaccelerated firmware path

The goal is to show how much faster a core that does the OS stuff would be than the CPU using the OS/
Specifically showing improvements in IOPS and p95/p99 latency over a CPU

Since it only processes reads and writes all it needs is one bit for read/write and the rest can go to metadata/address
speed up cache misses, tlb misses, read/write dependences, kernel bypasses