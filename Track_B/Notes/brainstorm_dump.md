ok so
goal is to have the GPU handle the IOPS of a next gen SSD
to truly make some sort of contribution, i need to understand how an SSD issues commands, and how a GPU handles instructions with 100% clarity
lets write what i already know

# initial brainstorm

### GPUs
- GPUs are built for parallization, they handle many instructions at once, as long as they are SIMD
- GPUs store the instructions they recive into chunks, and once a chunk is full, run the entire chunk at once
### GPU Questions
- How exactly does the data enter/exit GPUs? Is there anything special that needs to be known?
- SSDs will be issuing read/writes, how can you accurately parallelize those in the GPU?

### SSDs
- SSDs are made up of multiple identical sections, that each have their own blocks(4MB), that have their own pages (4KB)
- erases (?) make a whole block unusable for microseconds
### SSD Questions

### Overall
GPUs are designed for consistent SIMD. Storage I/O can be irregular and latency prone. How to convert Storage I/O into consistent streams for the GPU?



# second brainstorm
i just watched a video on SSDs to understand how they handle reads and writes better

SSDs handle reads fine, write include an erase. to get around the 2ms wait for an erase, writes are done out of order, where they go to an already erased page, and then the old page is garbage collected

so basically, the SSD is already well optimized to do many reads or writes. the real problem to tackle here is how do you make it so that the GPU is responsable for the throughput of the SSD instead of the CPU. 

things i need to learn
how exactly the CPU issues commands to the SSD
how exactly the CPU recieves commands from the SSD

if I can figure out how the CPU issues/recieves commands, it will help with figuring out how to parallelize them for a GPU
CPU issues commands using the NVMe protocol through PCIe

ideas so far:
all r/w have an address. using the last n bits of the addy, make that r/w go to whatever 2^n SM the n bits point to. the goal with this would be to group commands with like address together to potentially make conflict avoidance easier

duplication of r/w to ensure that enough are packaged together to be parallelized. in times where r/w are not frequent enough to make a whole package quickly, duplicate them, or even add bogus r/w, so that the actual commands can be run through the GPU