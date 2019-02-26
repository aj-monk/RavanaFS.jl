# Reserved blocks on thimble. To utilize a new reserved block, increment
# and use till RESERVED_BLKS.
const NAMESPACE_MAP = 0    # Directory map of entire fs goes here
const ROOT          = 1    # Entire namespace goes here
const THIMBLE_ARGS  = 2    # Thimble specific args
const NS_CHK_PT     = 3    # Checkpoint of the namespace
const RESERVED_BLKS = 4096 # Reserve this many blocks for Ravana's internal use

const FS_VERSION   = 1   # File system layout version

const BLOCK_SIZE   = UInt64(4096) # Data block size
const fid_t = UInt128  # File id, aka inode number
fid_t() = fid_t(rand(fid_t) + RESERVED_BLKS)

const id_t = UInt128   # Caution! this should match the one in Thimble

const LOGGER_PROC       = 2
const NS_WORKER_PROC    = 3
const DATA_WORKER1_PROC = 4
const DATA_WORKER2_PROC = 5
const NUM_WORKERS       = 2
const NUM_PROCS = 4

const RFS_PROTO_VERSION  = UInt32(1)
const RFS_FSAL_CLIENT    = UInt32(1)
const RFS_JULIA_CLIENT   = UInt32(2)

@enum Ftype DIR FILE CHAR BLOCK FIFO SOCK LINK
mutable struct RavanaFs
    cid::id_t
    sid::id_t
end
RavanaFs() = RavanaFs(0, 0)

# Ravana protocol
#    Client and server pass each other packets of the form:
#    type
#        size::UInt32           # Size of payload
#        version::UInt32        # Protocol version
#        flags::UInt32          # Protocol flags
#        payload::Vector{UInt8} # Payload
#    end
#    If the flag indicates a fsal client, then the payload is serialized using
#    msgpack. If the client is julia then the payload is serialized using
#    Julia's IO serializer.

mutable struct rfs_header_t
    size::UInt32        # Size
    version::UInt16     # Proto version
    flags::UInt16       # Proto flags
end

# Fs Ops
const OP_LOOKUP      = Int32(1)
const OP_READDIR     = Int32(2)
const OP_CREATE      = Int32(3)
const OP_MKDIR       = Int32(4)
const OP_SYMLINK     = Int32(5)
const OP_READLINK    = Int32(6)
const OP_TEST_ACCESS = Int32(7)
const OP_GETATTRS    = Int32(8)
const OP_SETATTRS    = Int32(9)
const OP_LINK        = Int32(10)
const OP_RENAME      = Int32(11)
const OP_UNLINK      = Int32(12)
const OP_OPEN        = Int32(13)
const OP_REOPEN      = Int32(14)
const OP_STATUS      = Int32(15)
const OP_READ        = Int32(16)
const OP_WRITE       = Int32(17)
const OP_COMMIT      = Int32(18)
const OP_LOCK        = Int32(19)
const OP_CLOSE       = Int32(20)
const OP_RMDIR       = Int32(21)
const OP_MKNOD       = Int32(22)

const OP_STOP_SERVER = Int32(1001)
const OP_UTIL_MKFS   = Int32(1002)
const OP_GET_SUPER   = Int32(1003)
const OP_PUT_SUPER   = Int32(1004)
const OP_MOUNT       = Int32(1005)
const OP_SYNC_FS     = Int32(1006)
const OP_CHK_PT      = Int32(1007)
const OP_SET_LOG_LEVEL = Int32(1008)

const OP_UNKNOWN     = Int32(10000)

mutable struct TimeSpec     # Equivalent to C's struct timespec
    sec::Int64    # Seconds
    nsec::Int64   # Nano seconds
end
function TimeSpec() # Constructor
    CLOCK_REALTIME_COARSE::Int32 = 5
    ts = TimeSpec(0, 0)
    status = ccall(:clock_gettime, Cint, (Cint, Ptr{TimeSpec}), CLOCK_REALTIME_COARSE, pointer_from_objref(ts))
    status != 0 && error("unable to determine current time: ", status)
    return ts
end

const S_IFMT   =  (0o170000)   #bit mask for the file type bit field
const S_IFSOCK =  (0o140000)   #socket
const S_IFLNK  =  (0o120000)   #symbolic link
const S_IFREG  =  (0o100000)   #regular file
const S_IFBLK  =  (0o060000)   #block device
const S_IFDIR  =  (0o040000)   #directory
const S_IFCHR  =  (0o020000)   #character device
const S_IFIFO  =  (0o010000)   #FIFO

macro set_flag(var, flag)
    quote
	var = var | flag
    end
end

function is_flag(var, flag)
    if var & flag == flag
        true
    else
        false
    end
end

KB(X) = X * (1 << 10)
MB(x) = x * (1 << 20)
GB(x) = x * (1 << 30)
TB(x) = x * (1 << 40)

# ATTR_MASK
# Used to set stat attributes after create and set attr
const ATTR_MODE =  UInt32(1 << 0)
const ATTR_UID  =  UInt32(1 << 1)
const ATTR_GID  =  UInt32(1 << 2)
const ATTR_SIZE =  UInt32(1 << 3)
const ATTR_ATIME = UInt32(1 << 4)
const ATTR_MTIME = UInt32(1 << 5)
const ATTR_CTIME = UInt32(1 << 6)

mutable struct FileAttr
    mode::UInt32     # File mode
    uid::UInt32      # Uid of owner
    gid::UInt32      # Group id
    links::UInt32    # Number of links
    size::UInt64     # for directories = num entries in it
    dev::id_t        # Channel id
    ino::fid_t       # inode num
    rdev::UInt32     # raw device number
    atime::TimeSpec  # Access time
    ctime::TimeSpec  # Change time
    mtime::TimeSpec  # Modification time
end
FileAttr() = FileAttr(UInt32(0), UInt32(0), UInt32(0),
                      UInt32(1), UInt64(0), id_t(0), fid_t(0),
                      UInt32(0), TimeSpec(), TimeSpec(),
                      TimeSpec())

# In-mem inode
mutable struct Inode
    fid::fid_t
    attr::FileAttr
end

mutable struct Fhandle
    inode::Inode
    fs::RavanaFs
end

mutable struct Dentry
    name::String
    fid::fid_t
    whence::UInt64
end

mutable struct RavanaSuper
    version::Int         # FS version
    pcid::id_t           # Parent channel id
    cid::id_t            # Backing channel id
    sid::id_t            # Last committed stream
    create_ts::DateTime  # Create time stamp
    mount_ts::DateTime   # Last mount time stamp TODO: change to timespec
    sync_ts::DateTime    # Last sync time
end
RavanaSuper() = RavanaSuper(0, 0, 0, 0, 0, 0, 0)

# Standard Unix error numbers faithfully copied from
# http://www-numi.fnal.gov/offline_software/srt_public_context/WebDocs/Errors/unix_system_errors.html
# And /usr/include/asm-generic/errno.h
const EPERM           =  UInt32(1)      # Operation not permitted
const ENOENT          =  UInt32(2)      # No such file or directory
const ESRCH           =  UInt32(3)      # No such process
const EINTR           =  UInt32(4)      # Interrupted system call
const EIO             =  UInt32(5)      # I/O error
const ENXIO           =  UInt32(6)      # No such device or address
const E2BIG           =  UInt32(7)      # Arg list too long
const ENOEXEC         =  UInt32(8)      # Exec format error
const EBADF           =  UInt32(9)      # Bad file number
const ECHILD          = UInt32(10)      # No child processes
const EAGAIN          = UInt32(11)      # Try again
const ENOMEM          = UInt32(12)      # Out of memory
const EACCES          = UInt32(13)      # Permission denied
const EFAULT          = UInt32(14)      # Bad address
const ENOTBLK         = UInt32(15)      # Block device required
const EBUSY           = UInt32(16)      # Device or resource busy
const EEXIST          = UInt32(17)      # File exists
const EXDEV           = UInt32(18)      # Cross-device link
const ENODEV          = UInt32(19)      # No such device
const ENOTDIR         = UInt32(20)      # Not a directory
const EISDIR          = UInt32(21)      # Is a directory
const EINVAL          = UInt32(22)      # Invalid argument
const ENFILE          = UInt32(23)      # File table overflow
const EMFILE          = UInt32(24)      # Too many open files
const ENOTTY          = UInt32(25)      # Not a typewriter
const ETXTBSY         = UInt32(26)      # Text file busy
const EFBIG           = UInt32(27)      # File too large
const ENOSPC          = UInt32(28)      # No space left on device
const ESPIPE          = UInt32(29)      # Illegal seek
const EROFS           = UInt32(30)      # Read-only file system
const EMLINK          = UInt32(31)      # Too many links
const EPIPE           = UInt32(32)      # Broken pipe
const EDOM            = UInt32(33)      # Math argument out of domain of func
const ERANGE          = UInt32(34)      # Math result not representable
const EDEADLK         = UInt32(35)      # Resource deadlock would occur
const ENAMETOOLONG    = UInt32(36)      # File name too long
const ENOLCK          = UInt32(37)      # No record locks available
const ENOSYS          = UInt32(38)      # Invalid system call number
const ENOTEMPTY       = UInt32(39)      # Directory not empty
const ELOOP           = UInt32(40)      # Too many symbolic links encountered
const EWOULDBLOCK     = EAGAIN  # Operation would block
const ENOMSG          = UInt32(42)      # No message of desired type
const EIDRM           = UInt32(43)      # Identifier removed
const ECHRNG          = UInt32(44)      # Channel number out of range
const EL2NSYNC        = UInt32(45)      # Level 2 not synchronized
const EL3HLT          = UInt32(46)      # Level 3 halted
const EL3RST          = UInt32(47)      # Level 3 reset
const ELNRNG          = UInt32(48)      # Link number out of range
const EUNATCH         = UInt32(49)      # Protocol driver not attached
const ENOCSI          = UInt32(50)      # No CSI structure available
const EL2HLT          = UInt32(51)      # Level 2 halted
const EBADE           = UInt32(52)      # Invalid exchange
const EBADR           = UInt32(53)      # Invalid request descriptor
const EXFULL          = UInt32(54)      # Exchange full
const ENOANO          = UInt32(55)      # No anode
const EBADRQC         = UInt32(56)      # Invalid request code
const EBADSLT         = UInt32(57)      # Invalid slot
const EBFONT          = UInt32(59)      # Bad font file format
const ENOSTR          = UInt32(60)      # Device not a stream
const ENODATA         = UInt32(61)      # No data available
const ETIME           = UInt32(62)      # Timer expired
const ENOSR           = UInt32(63)      # Out of streams resources
const ENONET          = UInt32(64)      # Machine is not on the network
const ENOPKG          = UInt32(65)      # Package not installed
const EREMOTE         = UInt32(66)      # Object is remote
const ENOLINK         = UInt32(67)      # Link has been severed
const EADV            = UInt32(68)      # Advertise error
const ESRMNT          = UInt32(69)      # Srmount error
const ECOMM           = UInt32(70)      # Communication error on send
const EPROTO          = UInt32(71)      # Protocol error
const EMULTIHOP       = UInt32(72)      # Multihop attempted
const EDOTDOT         = UInt32(73)      # RFS specific error
const EBADMSG         = UInt32(74)      # Not a data message
const EOVERFLOW       = UInt32(75)      # Value too large for defined data type
const ENOTUNIQ        = UInt32(76)      # Name not unique on network
const EBADFD          = UInt32(77)      # File descriptor in bad state
const EREMCHG         = UInt32(78)      # Remote address changed
const ELIBACC         = UInt32(79)      # Can not access a needed shared library
const ELIBBAD         = UInt32(80)      # Accessing a corrupted shared library
const ELIBSCN         = UInt32(81)      # .lib section in a.out corrupted
const ELIBMAX         = UInt32(82)      # Attempting to link in too many shared libraries
const ELIBEXEC        = UInt32(83)      # Cannot exec a shared library directly
const EILSEQ          = UInt32(84)      # Illegal byte sequence
const ERESTART        = UInt32(85)      # Interrupted system call should be restarted
const ESTRPIPE        = UInt32(86)      # Streams pipe error
const EUSERS          = UInt32(87)      # Too many users
const ENOTSOCK        = UInt32(88)      # Socket operation on non-socket
const EDESTADDRREQ    = UInt32(89)      # Destination address required
const EMSGSIZE        = UInt32(90)      # Message too long
const EPROTOTYPE      = UInt32(91)      # Protocol wrong type for socket
const ENOPROTOOPT     = UInt32(92)      # Protocol not available
const EPROTONOSUPPORT = UInt32(93)      # Protocol not supported
const ESOCKTNOSUPPORT = UInt32(94)      # Socket type not supported
const EOPNOTSUPP      = UInt32(95)      # Operation not supported on transport endpoint
const EPFNOSUPPORT    = UInt32(96)      # Protocol family not supported
const EAFNOSUPPORT    = UInt32(97)      # Address family not supported by protocol
const EADDRINUSE      = UInt32(98)      # Address already in use
const EADDRNOTAVAIL   = UInt32(99)      # Cannot assign requested address
const ENETDOWN        = UInt32(100)     # Network is down
const ENETUNREACH     = UInt32(101)     # Network is unreachable
const ENETRESET       = UInt32(102)     # Network dropped connection because of reset
const ECONNABORTED    = UInt32(103)     # Software caused connection abort
const ECONNRESET      = UInt32(104)     # Connection reset by peer
const ENOBUFS         = UInt32(105)     # No buffer space available
const EISCONN         = UInt32(106)     # Transport endpoint is already connected
const ENOTCONN        = UInt32(107)     # Transport endpoint is not connected
const ESHUTDOWN       = UInt32(108)     # Cannot send after transport endpoint shutdown
const ETOOMANYREFS    = UInt32(109)     # Too many references: cannot splice
const ETIMEDOUT       = UInt32(110)     # Connection timed out
const ECONNREFUSED    = UInt32(111)     # Connection refused
const EHOSTDOWN       = UInt32(112)     # Host is down
const EHOSTUNREACH    = UInt32(113)     # No route to host
const EALREADY        = UInt32(114)     # Operation already in progress
const EINPROGRESS     = UInt32(115)     # Operation now in progress
const ESTALE          = UInt32(116)     # Stale file handle
const EUCLEAN         = UInt32(117)     # Structure needs cleaning
const ENOTNAM         = UInt32(118)     # Not a XENIX named type file
const ENAVAIL         = UInt32(119)     # No XENIX semaphores available
const EISNAM          = UInt32(120)     # Is a named type file
const EREMOTEIO       = UInt32(121)     # Remote I/O error
const EDQUOT          = UInt32(122)     # Quota exceeded
const ENOMEDIUM       = UInt32(123)     # No medium found
const EMEDIUMTYPE     = UInt32(124)     # Wrong medium type
const ECANCELED       = UInt32(125)     # Operation Canceled
const ENOKEY          = UInt32(126)     # Required key not available
const EKEYEXPIRED     = UInt32(127)     # Key has expired
const EKEYREVOKED     = UInt32(128)     # Key has been revoked
const EKEYREJECTED    = UInt32(129)     # Key was rejected by service
const EOWNERDEAD      = UInt32(130)     # Owner died
const ENOTRECOVERABLE = UInt32(131)     # State not recoverable
const ERFKILL         = UInt32(132)     # Operation not possible due to RF-kill
const EHWPOISON       = UInt32(133)     # Memory page has hardware error


abstract type RavanaException <: Exception end

mutable struct RavanaInvalidIdException <: RavanaException
    msg::AbstractString
    errno::UInt32
end

mutable struct RavanaInvalidHandleException <: RavanaException
    msg::AbstractString
    errno::UInt32
end

mutable struct RavanaInvalidArgException <: RavanaException
    msg::AbstractString
    errno::UInt32
end

mutable struct RavanaUnexpectedFailureException <: RavanaException
    msg::AbstractString
    errno::UInt32
end

mutable struct RavanaEExists <: RavanaException
    msg::AbstractString
    errno::UInt32
end

mutable struct RavanaProtoException <: RavanaException
    msg::AbstractString
    errno::UInt32
end

mutable struct RavanaOplogException <: RavanaException
    msg::AbstractString
    errno::UInt32
end

mutable struct PerfStats
    loc::String
    on::Bool
    elapsed_time::Float64
    alloced::Int64
    count::Int64
end

const pcounter = Dict{String, PerfStats}()
const def_state = true # Turns on counters by default
macro pcount(locate::String, ex::Expr)
    quote
        local val::Any
        try
            p = pcounter[$locate]
            p.on == false && return $(esc(ex)) # return if counter is turned off
            local stats = Base.gc_num()
            local elapsedtime = time_ns()
            val = $(esc(ex))
            elapsedtime = time_ns() - elapsedtime
            local diff = Base.GC_Diff(Base.gc_num(), stats)

            p.elapsed_time += elapsedtime
            p.alloced += diff.allocd
            p.count += 1
        catch e
            val = $(esc(ex))
            if isa(e, KeyError)
                # Discard compile time by setting counters to 0
                pcounter[$locate] = PerfStats($locate, def_state, 0, 0, 0)
            end
        end
        val
    end
end

function bytes(b)
    b > (1 << 40) && return (string(round(b/(1 << 40), 2)) * " TB")
    b > (1 << 30) && return (string(round(b/(1 << 30), 2)) * " GB")
    b > (1 << 20) && return (string(round(b/(1 << 20), 2)) * " MB")
    b > (1 << 10) && return (string(round(b/(1 << 10), 2)) * " KB")
end

lt_perf(x::PerfStats, y::PerfStats) = (x.elapsed_time < y.elapsed_time)
function pget()
    @printf("%18s %8s %8s %9s %9s %7s\n", "Id", "Time", "Avg_Time",
            "Allocated", "Avg_Alloc", "Count")
    for i in sort(collect(values(pcounter)), lt=lt_perf, rev=true)
        @printf("%18s %8.2f %8.2f %9s %9s %7d\n",
                i.loc[1:min(length(i.loc), 18)],
                i.elapsed_time/1e9, i.elapsed_time/(1e9 * i.count),
                bytes(i.alloced), bytes(i.alloced/i.count - 1),
                i.count)
    end
end

hex(n) = string(n, base=16)

function Base.zeros(x::PerfStats)
    x.elapsed_time = 0
    x.alloced = 0
    x.count = 0
end

function pclear()
    for i in collect(values(pcounter))
        zeros(i)
    end
end

function pswitch(locate::String, state::Bool)
    try
        p = pcounter[locate]
        p.on = state
        !p.on && zeros(p)
    catch e
        if isa(e, KeyError)
            # do nothing
        end
    end
end

"""
    wait_for(s::Float64, exp::Expression)
Wait for *s* seconds or expression *exp* to evaluate to true, whichever
happens earlier.
"""
macro wait_for(s::Float64, exp::Expr)
    quote
        timer = 0
        tick = 0.1
        decay = 2
        while timer < s || $(esc(exp)) != true
            sleep(tick)
            timer += tick
            tick *= decay
        end
    end
end

function ravana_cleanup()
    dispatch_cleanup(".")
    controller_cleanup()
end
