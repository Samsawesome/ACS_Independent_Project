https://www.usenix.org/system/files/atc19-lee-gyusun.pdf "Asynchronous I/O Stack: A Low-latency Kernel I/O Stack for Ultra-Low Latency SSDs"

This paper's goal is to develop an asynchronous I/O stack to deal with the increasing speed of I/O commands from low latency SSDs.

The important part of the paper for me is that their asynch I/O stack skips the block layer entirely, and hopefully that crossover with my idea will lead to some helpful insights in this paper.

Things I learned from this paper:

"When an application issues a read I/O request, a page is allocated and indexed in a page cache. Then, a DMA mapping is made and several auxiliary data structures (e.g., bio, request, iod in Linux) are allocated and manipulated. The issue here is that these operations occur synchronously before an actual I/O command is issued to the device. With ultra-low latency SSDs, the time it takes to execute these operations is comparable to the actual I/O data transfer time."

Takeaway: Earlier I said that the earlier part of the process (described here) has little room for optimization, but it seems this area too could benifit from asyncronity or parallelism. (Which is partly what the paper does)

"Linux batches several block requests issued by a thread in order to increase the efficiency of request handling in the underlying layers (also known as queue plugging)."

Takeaway: I did not know block requests were batched together, and it might be something I can do on the hardware side as well.

Very nice diagrams that showcase the specifics of the default read path versus their proposed read path, along with other diagrams that show the overview of the block layer and other proposed command paths.

Need to finish reading