https://atlarge-research.com/pdfs/2023-cheops-iostack.pdf (Performance Characterization of Modern Storage Stacks: POSIX I/O, libaio, SPDK, and io_uring)

This paper's goal is to measure the various Linux storage I/O stacks and APIs to determine their performance and overheads.

The important part of this paper for me is the overview of the Linux storage stack. It has a nice diagram and description of the entire Linux storage stack that goes into detail of what happens when in the overall I/O process.

Things I learned from this paper:

SPDK is a Linux storage stack that bypasses the kernel completely by providing direct access to NVMe SSDs from the userspace. It is considered state of the art and is considered to have the best performance among all of the I/O stacks. "However, user space I/O libraries lack many kernel-supported features such as fine-grained isolation, access control, file systems, multi tenancy, and QoS support.", which I understand to mean that SPDK is either not fully supported on all Linux versions, all machines, or all user spaces. 

Takeaway: IOPS core must be faster than kernel-bypassing storage stacks as well as ones that use the kernel.

Linux storage stack is as follows. 1 I/O requests (reads/writes) -> 2 VFS (formats) -> 3 struct bio (w address) -> 4 struct request -> 5 per-core software queue -> 6 block I/O scheduler -> 7 hardware dispatch queue -> 8 NVMe driver -> 9 NVMe command -> 10 submission queue -> 11 device -> 12 completion queue + interrupt

There are a couple more processes at the end but for this project I really only care about the steps before getting to the device. My first impression is that some steps are unavoidable/hard to optimize using hardware (such as 1, for unavoidable, and 2-4, for hard to optimize using hardware). However, certain steps, such as the ones that involve queues, seem like they could be optimized using hardware. In specific, if NVMe drivers were taken off of the CPU, everything from step 5-10/12 seems as if it could be off of the CPU. My vision is that once the request is in the correct data type, it could be taken off chip to the IOPS core. This IOPS core would handle putting the request in a queue, scheduling the block I/O, putting that in a dispatch queue (which is already hardware), and then communicating with NVMe drivers and submission/completion queue. Then the interrupt that would be generated would go back onto the CPU, which I know is already done with certain devices (meaning off CPU interrupts exist already). Essentially, the entire block queue would be taken off of the CPU and go onto a IOPS core. This IOPS core would be faster because 1 it is designed specifically to do this 2 it can be parallelized more than the amount of cores on the CPU and 3 it reduces software overhead.

Takeaway: It seems to be  feasable to create an IOPS core that takes a large part of the storage stack off of the CPU.

