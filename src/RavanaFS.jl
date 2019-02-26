__precompile__()

"""
# Ravana - A file system with replacable heads for your monstrous data needs

Ravana is a fault tolerant file server that can store exabytes of data
spread across a cluster of machines. For a particular file share there is
a machine that acts as the conduit, taking requests for file system
operations. We shall refer to this machine as "The Head".

Ravana is not multi-headed in that it does not allow multiple operations
simultaneously from more than 1 head (master/machine). However it is fault
tolerant - it is replicated, so if a head is severed it can resume operations
on another machine. This master-slave approach simplifies the implementation.
In any case the dominant protocols of the day - NFS and SMB don't support
multiple simultaneous masters. Ravana's architecture is capable of p-NFS
style parallel data operations with a single fault tolerant meta-data
master.

Ravana is designed to be a fast file system front end to a secondary storage
system (Thimble). It works by taking check points, also called snapshots,
which are backed up to Thimble. Operations after the last checkpoint are
logged in a distributed op-log. If a head crashes, a new head recovers the
current state by replaying the op-log. State that is stored before the last
checkpoint is obtained from Thimble.

In order to speed up operations Ravana maintains on the Head a complete
copy of its name-space (directory structure). It also keeps a persistent
cache of data blocks.

## Dependencies
Ravana does not exist in isolation. It depends on:
1. A non-distributed key-value store (KVS) to keep
   a.) A local copy of the op-log containing meta-data.
   b.) A local copy of the directory structure.
   c.) A local copy of the most recently used data blocks.
2. An eventually consistent key-value store (KVS) to keep
   a.) A remote copy of the op-log containing meta-data and data.
3. A fully consistent KVS to track checkpoints.
4. A secondary storage system to store the file system state up to
   the last checkpoint.

## Implementation

Ravana is implemented as multiple single threaded processes that communicate
via IPC. All processes run on the head.
       -----------------------------------------------------
      ↑                                                   ↓
 + ----------+     +----------------------+     +----------------------+
 | Dispatcher| →  | NameSpaceWorker (FS1)|     | NameSpaceWorker (FS2)|
 + ----------+     +----------------------+     +----------------------+
                   +----------------------+     +----------------------+
                   | DataWorker %1  (FS1) |     | DataWorker %1  (FS2) |
                   +----------------------+     +----------------------+
                   +----------------------+     +----------------------+
                   | DataWorker %2  (FS1) |     | DataWorker %2  (FS2) |
                   +----------------------+     +----------------------+
                   +----------------------+     +----------------------+
                   | DataWorker %3  (FS1) |     | DataWorker %3  (FS2) |
                   +----------------------+     +----------------------+
                   +----------------------+     +----------------------+
                   | DataWorker %0  (FS1) |     | DataWorker %0  (FS2) |
                   +----------------------+     +----------------------+

### Dispatcher
The unified dispatcher is either a thread that sits in the protocol layer
or a separate process that mediates between the user/protocol and workers.
It generates a monotonically increasing 64 bit sequence number for each new
request. The sequence number and operation are logged in a key-value store:
(sequence no) => (operation)
A 64 bit sequence number will take half million years to overflow if operations
are generated at 1 every micro second. So we don't care about overflows.
    (BigInt(2)^64 - 1) / (60*60*24*365*1000000)
    5.84942417355072032e+05

If replication is configured there are 2 ways to go about it:
1. A copy of the (sequence no, operation) is sent to the slave(s) where it
   is logged.
2. The key-value store used to keep the dispatcher op-log is a distributed
   replicated KVS.
(1) has the advantage of control. We can decide the nodes where the op-log
will be stored. It allows us to keep 1 copy locally so that reads of the
op-log will be fast.
(2) has the advantage that we can use ready-made solutions, but we lose
control of data placement.

We opt for a hybrid approach. We use a non-distributed KVS locally. A
distributed KVS is used to store more copies of the op-log. The cluster
that forms the distributed KVS is ideally a different availability zone.

    The Head                     Another Availability Zone
 +-----------------+       +----------------------------------+
 |  + ----------+  |       |                                  |
 |  | Protocol  |  |       |         +----------------------+ |
 |  +-----------+  |       |         | Distributed KVS Node | |
 |       ↓        |       |         +----------------------+ |
 |  + ----------+  |       | +----------------------+         |
 |  | Dispatcher|  →  →  | | Distributed KVS Node |         |
 |  + ----------+  |       | +----------------------+         |
 |       ↓        |       |         +----------------------+ |
 |  + ----------+  |       |         | Distributed KVS Node | |
 |  | Local KVS |  |       |         +----------------------+ |
 |  +-----------+  |       +----------------------------------+
 +-----------------+

For write operations to regular files only the ranges and not the actual
content is logged locally. This is to avoid double data writes. In the
distributed KVS the range and content are logged for high availability.

### Workers
Each RavanaFS exported from a node has 1 NameSpaceWorker and 1 or more
DataWorker processes. The NameSpaceWorker handles all directory read/write
requests for a given RavanaFS. The DataWorkers handle read/write and meta-data
changes to regular files. (At this point we don't see the need to support device
files). If there are more than 1 DataWorkers for an FS then each DataWorker
handles requests for files whose inode_no % N == DataWorker_id. For the first
release we fix the number of DataWorker processes per FS. Schemes like
consistent hashing may be considered for a later release.

### NameSpaceWorker
Directory entries are stored in a key-value store that maps
(parent dir inode no, file name) => file inode no
The file inode no is a generated 128 bit random number. So no locking is
required to generate an inode no.

From http://preshing.com/20110504/hash-collision-probabilities/, the
probability of collision of k randomly chosen integers from a pool of N
integers is k^2/(2*N). For 100 billion files the probability of collision is:
    ((BigInt(10)^11)^2)/((BigInt(2)^128)*2)
    1.4693679e-17
That is 1 in 10^17, or 1000 times less likely than a meteor landing on your
home. Uncorrectable DRAM errors are likely to occur much before a inode no
collision (http://www.cs.toronto.edu/~bianca/papers/sigmetrics09.pdf).

There are separate KVSs for directory entries and for regular files. So
creating, deleting or renaming files/directories is a 2-phase non-atomic
operation. This can cause problems during failures/crashes if 1 leg of the
operation is complete but not the other. The dispatcher's op-log and our
usage of random inode numbers help here. The op-log entry works as an
"intent to execute".

#### Create
The dispatcher generates a random inode no and logs the intent to create
a file with that inode number. It passes the inode no to the NameSpaceWorker
along with an instruction to create a directory entry. If a file already
exists with the given name, the NameSpaceWorker returns an error which
the dispatcher propagates back to the user/protocol. If the directory
entry is created the Dispatcher instructs the DataWorker to create an
inode with the given number.

#### Unlink (delete)
The dispatcher writes an intent to unlink before instructing the DataWorker
and NameSpaceWorker to unlink the file.

#### Rename
Rename is a single phase operation that is executed by the NameSpaceWorker.

#### Name Space Recovery
TBD

### DataWorker

### Data Recovery

### Checkpointing aka Snapshots

"""
module RavanaFS
# Depending modules
# using Thimble
using Logging
using KVS
using Dates
using Printf
using Distributed
using Sockets
using Dates

# Set default logging level
global_logger(ConsoleLogger(stderr, Logging.Debug, Logging.default_metafmt, true, 0, Dict{Any, Int64}()))

# Module Initializer
function __init__()
    controller()
    # init_dispatcher() # Starts dispatch task
    #atexit(ravana_cleanup()) # Module cleanup
end

# Exported
export fileOps, fid_t, id_t, FileAttr
export mkfs, mount, rfs_lookup, rfs_create, rfs_getattr, rfs_setattr, rfs_mkdir, rfs_rmdir
export rfs_readdir, rfs_write, rfs_read, rfs_symlink, rfs_link, rfs_rename, rfs_unlink
export rfs_cd, rfs_rm
export xcopy, ll, rfs_touch, cksum
export RavanaFS
export ATTR_MODE, ATTR_UID, ATTR_GID, ATTR_SIZE, ATTR_ATIME, ATTR_MTIME
export checkpoint, restart, syncpoint, clone, set_log_level, set_cfs
export @pcount, pget, pclear, pswitch

# Source Files
include("RavanaDeclarations.jl")
include("RavanaDb.jl")
include("Serialize.jl")
include("RavanaDispatcher.jl")
include("Controller.jl")
include("RavanaLogger.jl")
include("NameSpaceWorker.jl")
include("DataWorker.jl")
include("Utils.jl")

# Deprecated

end # module RavanaFS
