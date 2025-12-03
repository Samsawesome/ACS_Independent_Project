http://www.mnis.fr/fr/services/virtualisation/pdf/LinuxSymposium2004_V1.pdf#page=51 "Linux Block IO—present and future"

This paper's goal is to describe the past, present, and future of the Linux Block I/O Stack.

The important part of the paper for me is that it goes in depth describing the Linux block I/O stack, especially talking about what worked and what didn't work. I hope to gleam some insight from past mistakes made by other people to hope to not repeat said mistakes.

Things I learned from this paper:

The 2.4 verions of Linux had very bad block layer code. This was mostly due to two things: trying to make data structs do multiple things at once, and an overall lack of planning and testing.

Takeaway: Plan out your code and test it.

"The core function of an IO scheduler is, naturally, insertion of new io units and extraction of ditto from drivers."

Takeaway: An IO scheduler must be in constant contact with the area where new io units are made(VFS?) and the drivers they return from.

"...the deadline IO scheduler. The principles behind it are pretty straight forward — new requests are assigned an expiry time in milliseconds, based on data direction. Internally, requests are managed on two different data structures. The sort list, used for inserts and front merge lookups, is based on a red-black tree. This provides O(log n) runtime for both insertion and lookups, clearly superior to the doubly linked list. Two FIFO lists exist for tracking request expiry times, using a double linked list. Since strict FIFO behavior is maintained on these two lists, they run in O(1) time. For back merges it is important to maintain good performance as well, as they dominate the total merge count due to the layout of files on disk. So deadline added a merge hash for back merges, ideally providing O(1) runtime for merges."

Takeway: The IO schedulers that exist in modern day are well optimized and will need to be equally sophisticated on the hardware time to ensure that the IOPS core saves time. A lot of these data structures can essentially be directly copied onto hardware though.