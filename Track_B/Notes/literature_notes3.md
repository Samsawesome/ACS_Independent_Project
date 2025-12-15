https://www.cs.sfu.ca/~tzwang/modern-storage-index.pdf SSDs Striking Back: The Storage Jungle and Its Implications on Persistent Indexes


This paper's goal is to show that the traditional storage hierarchy has turned into a storage jungle, and to analyize whether PM techniques or NVMe based SSD techniques are better in these decreased latency environments.

The important part of the paper for me is that the author investigates techniques to use that are suitable for ultra low latency SSD environments, and also goes into great detail of the storage jungle in general.


Things I learned from this paper:

"Storage Jungle" - meaning the components of the storage hierarchy are starting to have overlapping performance. 

Takeaway: Things are changing compared to how they have always been, and that always leads to technological improvements.

"Driven by faster storage, I/O interfaces have also evolved to be much more lightweight with new programming models such as SPDK and io_uring, further reducing overhead caused by the storage stack at the software level."

Takeaway: People have known IO interfaces have needed to improve for a while, and have started working on them, but no real work has been made towards really disrupting the IO stack.

"As the latency gap between SSD and PM continues to shrink, PM’s low-latency commit may not tremendously benefit them. This naturally leads to a simple, motivating question: Could a well-tuned SSD-based data structure (e.g., index) match or outperform a well-tuned PM-tailored data structure under certain workloads?"

Takeaway: While PM is very fast, it has its own flaws, and SSDs cathcing up to PM in speed has started to expose these flaws.

"PM prices need to drop for true cost-effectiveness."

Takeaway: While low latency is important, it is not the only factor that matters when designing a computer system. The entire system must be taken into account, and it happens that PM requires a lot of changes to be made to the system that results in a larger cost overall.

"For memory-resident workloads (e.g., many OLTP workloads), caching stores are more cost-effective than PM, mainly due to PM’s population rules that overprovision DRAM and CPU."

Takeaway: PM is fast, but for lots of  real world problems, it is not the optimal solution. Again, all variables must be taken into account, and just because PM has lower latency does not mean it is always faster overall.