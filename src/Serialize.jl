"""
Functions in this file do packing/unpacking of arguments passed
into and out of dispatch_server. The structure of things passed
in and out is defined in the C header file ravana.h.

    rfs_X_unpack(io)
Unpacks all arguments from the iobuffer or iostream *io* for the
given operation X (example: rfs_create_unpack). These routines
are called to decipher the arguments passed to the server.

    rfs_X_ret(io, ret_val, jl::Bool)
Packs return values *ret_val* for the operation X. *ret_val* is
usually a tuple. *jl* is a boolean that is true if the client
calling the op is Julia.

There are helper function to pack/unpack complex structures,
for instance rfs_attr_unpack() unpacks FileAttrs and
rfs_attr_pack() packs it as a return value.
"""

const NO_ERROR = UInt32(0)

function lower64(num::UInt128)
    return UInt64(num & ((UInt128(1) << 64)-1))
end

function upper64(num::UInt128)
    return UInt64(num >> 64)
end

function UInt128(lo::UInt64, up::UInt64)
    return UInt128(UInt128(up) << 64 | lo)
end

function return_to_jl_client(sock, ret)
    b = byte_array(ret)
    write(sock, length(b), b)
end

function rfs_timespec_unpack(iob)
    sec = Int64(MsgPack.unpack(iob))
    nsec = Int64(MsgPack.unpack(iob))
    TimeSpec(sec, nsec)
end

function rfs_attr_unpack(iob)
    mode = UInt32(MsgPack.unpack(iob))
    uid  = UInt32(MsgPack.unpack(iob))
    gid  = UInt32(MsgPack.unpack(iob))
    links = UInt32(MsgPack.unpack(iob))
    size  = UInt64(MsgPack.unpack(iob))
    lo::UInt64 = MsgPack.unpack(iob)
    up::UInt64 = MsgPack.unpack(iob)
    dev = UInt128(lo, up)
    lo = MsgPack.unpack(iob)
    up = MsgPack.unpack(iob)
    ino = UInt128(lo, up)
    rdev = UInt32(MsgPack.unpack(iob))
    atime = rfs_timespec_unpack(iob)
    ctime = rfs_timespec_unpack(iob)
    mtime = rfs_timespec_unpack(iob)
    attr = FileAttr(mode, uid, gid, links, size, dev, ino, rdev, atime, ctime, mtime)
end

function rfs_fid_pack(iob, fid::fid_t)
    MsgPack.pack(iob, lower64(fid))
    MsgPack.pack(iob, upper64(fid))
end

function rfs_cid_pack(iob, cid::id_t)
    MsgPack.pack(iob, lower64(cid))
    MsgPack.pack(iob, upper64(cid))
end

function rfs_timespec_pack(iob, t::TimeSpec)
    MsgPack.pack(iob, t.sec)
    MsgPack.pack(iob, t.nsec)
end

function rfs_attr_pack(iob, a::FileAttr)
    MsgPack.pack(iob, a.mode)
    MsgPack.pack(iob, a.uid)
    MsgPack.pack(iob, a.gid)
    MsgPack.pack(iob, a.links)
    MsgPack.pack(iob, a.size)
    rfs_cid_pack(iob, a.dev)
    rfs_fid_pack(iob, a.ino)
    MsgPack.pack(iob, a.rdev)
    rfs_timespec_pack(iob, a.atime)
    rfs_timespec_pack(iob, a.ctime)
    rfs_timespec_pack(iob, a.mtime)
end

function rfs_u128_unpack(iob)
    lo::UInt64 = MsgPack.unpack(iob)
    up::UInt64 = MsgPack.unpack(iob)
    UInt128(lo, up)
end

rfs_cid_unpack(iob) = rfs_u128_unpack(iob)
rfs_fid_unpack(iob) = rfs_u128_unpack(iob)

#=
Unpack this:
typedef struct rfs_arg_lookup {
    rfs_file_op_t op;        // operation code
    cid_t         cid;       // channel id
    fid_t         dfid;      // Parent dir's fid
    file_name_t   fname;     // File name
} rfs_arg_lookup_t;
=#
function rfs_lookup_unpack(iob)
    cid = rfs_cid_unpack(iob)
    dfid = rfs_fid_unpack(iob)
    fname = String(MsgPack.unpack(iob))
    # return (op, args, ro, ns, jl)
    return (OP_LOOKUP, (dfid, fname), true, true, false)
end

# Unpack for julia
function rfs_lookup_unpack(args::Tuple)
    return (OP_LOOKUP, args, true, true, true)
end

"""
Takes two arguments iob and ret value. If ret is an 
RavanaException, it fills iob with ret.errno
If it's a general Exception, fills ENODATA
"""
function check_exception(iob, ret)
    if isa(ret, RavanaException)
        write(iob, ret.errno)
        return true
    elseif isa(ret, Exception)
        write(iob, ENODATA)
        return true
    end
    return false
end

#=
Return this:
typedef struct rfs_rsp_lookup {
    int           error;      // POSIX error
    fid_t         fid;        // fid of the looked up file
} rfs_rsp_lookup_t;
=#
function rfs_lookup_ret(sock, attrs, jl)
    if jl
        return_to_jl_client(sock, attrs)
    else
        iob = IOBuffer()
        if !check_exception(iob, attrs)   # On exception set errno
            MsgPack.pack(iob, NO_ERROR)   # errno
            rfs_attr_pack(iob, attrs)     # file attributes
        end
        write(sock, UInt32(length(iob.data)), iob.data)
    end
end

#=
Unpack this:
typedef struct rfs_arg_readdir {
    rfs_file_op_t  op;        // operation code
    cid_t          cid;       // channel id
    fid_t          d_fid;     // directory file id
    uint64_t       index;     // index to start from
} rfs_arg_readdir_t;
=#
function rfs_readdir_unpack(iob)
    cid = rfs_cid_unpack(iob)
    d_fid = rfs_fid_unpack(iob)
    index = UInt64(MsgPack.unpack(iob))
    @debug("readdir() on $d_fid")
    # return (op, args, ro, ns, jl)
    return (OP_READDIR, (d_fid, index), true, true, false)
end

# Unpack for julia
function rfs_readdir_unpack(args::Tuple)
    return (OP_READDIR, args, true, true, true)
end

function rfs_dentries_pack(iob, dentries::Vector{Dentry})
    for d in dentries
        @debug("readdir(): packing $(d.name)")
        MsgPack.pack(iob, d.name)
        rfs_fid_pack(iob, d.fid)
        MsgPack.pack(iob, d.whence)
    end
end

#=
Return this
typedef struct rfs_dirent {
    file_name_t fname;        // File Name
    fid_t       fid;          // fid
} rfs_dirent_t;
typedef struct rfs_rsp_readdir {
    int32_t      error;       // POISX error
    int32_t      eof;         // true, for end of directory
    uint32_t     n_entries;   // number of entries returned
    rfs_dirent_t entries[];   // readdir entries
} rfs_rsp_readdir_t;
=#
function rfs_readdir_ret(sock, ret, jl)
    if jl
        return_to_jl_client(sock, ret)
    else
        iob = IOBuffer()
        if !check_exception(iob, ret)	#If ret is an exception fill ret.errno in iob
            (dirs, eof) = ret
            MsgPack.pack(iob, NO_ERROR)
            MsgPack.pack(iob, eof)
            MsgPack.pack(iob, UInt32(length(dirs)))
            rfs_dentries_pack(iob, dirs)
        end
        @debug(iob.data)
        write(sock, UInt32(length(iob.data)), iob.data)
    end
end

#=
Unpack this:
typedef struct rfs_arg_create {
    rfs_file_op_t op;         // operation code
    cid_t         cid;        // channel id
    fid_t         p_fid;      // parent file id
    uint32_t      attr_mask;  // attr mask to set
    file_name_t   fname;      // File name
    FileAttr      attr;       // attrs to set
} rfs_arg_create_t;
=#
function rfs_create_unpack(iob)
    cid = rfs_cid_unpack(iob)
    p_fid = rfs_fid_unpack(iob)
    attr_mask = UInt32(MsgPack.unpack(iob))
    fname = String(MsgPack.unpack(iob))
    @debug("create: p_fid=$p_fid fname=$fname")
    attr = rfs_attr_unpack(iob)
    @debug("attr: $attr")
    return (OP_CREATE, (p_fid, fid_t(), fname, attr_mask, attr), false, true, false)
end

# Unpack for julia
function rfs_create_unpack(args::Tuple)
    (p_fid, fname, attr_mask, attr) = args
    return (OP_CREATE, (p_fid, fid_t(), fname, attr_mask, attr), false, true, true)
end

#=
Return this:
typedef struct rfs_arg_create {
    rfs_file_op_t op;         // operation code
    cid_t         cid;        // channel id
    fid_t         p_fid;      // parent file id
    uint32_t      attr_mask;  // attr mask to set
    file_name_t   fname;      // File name
    FileAttr      attr;       // attrs to set
} rfs_arg_create_t;
=#


#=
Unpack this:
typedef struct rfs_arg_create {
    rfs_file_op_t op;         // operation code
    cid_t         cid;        // channel id
    fid_t         p_fid;      // parent file id
    uint32_t      attr_mask;  // attr mask to set
    file_name_t   fname;      // File name
    FileAttr      attr;       // attrs to set
} rfs_arg_create_t;
=#
function rfs_mknod_unpack(iob)
    cid = rfs_cid_unpack(iob)
    p_fid = rfs_fid_unpack(iob)
    attr_mask = UInt32(MsgPack.unpack(iob))
    fname = String(MsgPack.unpack(iob))
    @debug("mknod: p_fid=$p_fid fname=$fname")
    attr = rfs_attr_unpack(iob)
    @debug("attr: $attr")
    return (OP_MKNOD, (p_fid, fid_t(), fname, attr_mask, attr), false, true, false)
end

"""
Will write to sock an iob with an errno or the file attr structure of the created file
"""
function rfs_create_ret(sock, ret, jl::Bool)
    if jl
        return_to_jl_client(sock, ret)
    else
        iob = IOBuffer()
        if !check_exception(iob, ret)	#If ret is an exception fill ret.errno in iob
            attrs = ret
            MsgPack.pack(iob, NO_ERROR) # errno
            rfs_attr_pack(iob, attrs)  # attrs
        end
        @debug("rfs_create_ret(): length=$(length(iob.data)) $(iob.data)")
        write(sock, UInt32(length(iob.data)), iob.data)
    end
end
#=
Unpack this
typedef struct rfs_arg_mkdir {
    rfs_file_op_t op;         // operation code
    cid_t         cid;        // channel id
    fid_t         p_fid;      // parent dir id
    uint32_t      attr_mask;  // attr mask to set
    file_name_t   dname;      // Dir name
    FileAttr      attr;       // attrs to set
} rfs_arg_mkdir_t;
=#
function rfs_mkdir_unpack(iob)
    cid = rfs_cid_unpack(iob)
    p_dfid = rfs_fid_unpack(iob)
    attr_mask = UInt32(MsgPack.unpack(iob))
    dname = String(MsgPack.unpack(iob))
    @debug("mkdir: p_dfid=$p_dfid dname=$dname")
    attr = rfs_attr_unpack(iob)
    @debug("attr: $attr")
    # Return (op, args tuple for op, read-only, namespace, julia-client)
    return (OP_MKDIR, (p_dfid, fid_t(), dname, attr_mask, attr), false, true, false)
end

# Unpack for julia
function rfs_mkdir_unpack(args::Tuple)
    (p_dfid, attr_mask, dname, attr) = args
    return (OP_MKDIR, (p_dfid, fid_t(), dname, attr_mask, attr), false, true, true)
end

#=
Return this
typedef struct rfs_rsp_mkdir {
    __int32_t     error;      // POSIX error
    FileAttr      attr;       // Attrs of newly created dir
} rfs_rsp_mkdir_t;

=#
function rfs_mkdir_ret(sock, ret, jl::Bool)
    if jl
        return_to_jl_client(sock, ret)
    else
        iob = IOBuffer()
        if !check_exception(iob, ret)	#If ret is an exception fill ret.errno in iob
            attrs = ret
            MsgPack.pack(iob, NO_ERROR) # errno
            rfs_attr_pack(iob, attrs)  # attrs
        end
        @debug("rfs_mkdir_ret(): length=$(length(iob.data)) $(iob.data)")
        write(sock, UInt32(length(iob.data)), iob.data)
    end
end

#=
Unpack this
typedef struct rfs_arg_symlink {
    rfs_file_op_t op;         // operation code
    cid_t         cid;        // channel id
    fid_t         p_fid;      // parent dir id
    uint32_t      attr_mask;  // attr mask to set
    file_name_t   name;       // Link name
    FileAttr      attr;       // attrs to set
    file_name_t	  link_path;  // path to link to
} rfs_arg_symlink_t;
=#
function rfs_symlink_unpack(iob)
    cid = rfs_cid_unpack(iob)
    p_dfid = rfs_fid_unpack(iob)
    attr_mask = UInt32(MsgPack.unpack(iob))
    fname = String(MsgPack.unpack(iob))
    attr = rfs_attr_unpack(iob)
    lpath = String(MsgPack.unpack(iob))
    @debug("symlink(): p_dfid=$p_dfid fname=$fname link path=$lpath")
    @debug("attr: $attr")
    # Return (op, args tuple for op, read-only, namespace, julia-client)
    return (OP_SYMLINK, (p_dfid, fid_t(), fname, lpath, attr_mask, attr), false, true, false)
end

# Unpack for julia
function rfs_symlink_unpack(args::Tuple)
    (p_dfid, attr_mask, fname, attr, lpath) = args
    return (OP_SYMLINK, (p_dfid, fid_t(), fname, lpath, attr_mask, attr), false, true, true)
end

#=
Return this
typedef struct rfs_rsp_symlink {
    __int32_t     error;      // POSIX error
    FileAttr      attr;       // Attrs of the link created
} rfs_rsp_symlink_t;
=#
function rfs_symlink_ret(sock, ret, jl)
   if jl
        return_to_jl_client(sock, ret)
    else
        iob = IOBuffer()
        if !check_exception(iob, ret)
            MsgPack.pack(iob, NO_ERROR) # errno
            rfs_attr_pack(iob, ret)   # attrs
        end
        write(sock, UInt32(length(iob.data)), iob.data)
    end
end

#=
Unpack this:
typedef struct rfs_arg_getattr {
    rfs_file_op_t   op;        // operation code
    cid_t           cid;       // channel id
    fid_t           fid;       // file id
} rfs_arg_getattr_t;
=#
function rfs_getattrs_unpack(iob)
    cid = rfs_cid_unpack(iob)
    fid = rfs_fid_unpack(iob)
    # return (op, args, ro, ns, jl)
    return (OP_GETATTRS, (fid), true, true, false)
end

# Unpack for julia
function rfs_getattrs_unpack(args::Tuple)
    return (OP_GETATTRS, args, true, true, true)
end

#=
Return this:
typedef struct rfs_rsp_getattr {
    int         error;        // POISX error
    FileAttr    attr;         // get attr resp
} rfs_rsp_getattr_t;
=#
function rfs_getattrs_ret(sock, ret, jl)
    if jl
        return_to_jl_client(sock, ret)
    else
        iob = IOBuffer()
        if !check_exception(iob, ret)
            attrs = ret
            MsgPack.pack(iob, NO_ERROR) # errno
            rfs_attr_pack(iob, attrs)   # attrs
        end
        write(sock, UInt32(length(iob.data)), iob.data)
    end
end

#=
Pack this:
typedef struct rfs_arg_setattr {
    rfs_file_op_t  op;         // operation code
    cid_t          cid;        // channel id
    fid_t          fid;        // file id
    uint32_t       attr_mask;  // attr mask to set
    FileAttr       attr;       // attrs to set
} rfs_arg_setattr_t;
=#
function rfs_setattrs_unpack(iob)
    cid = rfs_cid_unpack(iob)
    fid = rfs_fid_unpack(iob)
    mask = UInt32(MsgPack.unpack(iob))
    attr = rfs_attr_unpack(iob)
    # return (op, args, ro, ns, jl)
    return (OP_SETATTRS, (fid, mask, attr), false, true, false)
end

# Unpack for julia
function rfs_setattrs_unpack(args::Tuple)
    return (OP_SETATTRS, args, false, true, true)
end

#=
Return this:
typedef struct rfs_rsp_setattr {
    int         error;        // POISX error
} rfs_rsp_setattr_t;
=#
function rfs_setattrs_ret(sock, ret, jl)
    if jl
        return_to_jl_client(sock, ret)
    else
        iob = IOBuffer()
        if !check_exception(iob, ret)
            @debug("setattr() no error")
            MsgPack.pack(iob, NO_ERROR) # errno
        end
        @debug("setattr(): $(iob.data)")
        write(sock, UInt32(length(iob.data)), iob.data)
    end
end

#=
Unpack this
typedef struct rfs_arg_link {
    rfs_file_op_t op;         // operation code
    cid_t         cid;        // channel id
    fid_t         p_fid;      // parent dir id
    fid_t         fid;        // file id to link to
    file_name_t   name;       // Link name
} rfs_arg_link_t;
=#
function rfs_link_unpack(iob)
    cid = rfs_cid_unpack(iob)
    p_fid = rfs_fid_unpack(iob)
    fid = rfs_fid_unpack(iob)
    fname = String(MsgPack.unpack(iob))
    @debug("link(): parent:$p_fid file_to_link:$fid link_name:$fname")
    return(OP_LINK, (p_fid, fid, fname), false, true, false)
end

# Unpack for julia
function rfs_link_unpack(args::Tuple)
    return (OP_LINK, args, false, true, true)
end

#=
Return this
typedef struct rfs_rsp_link {
    __int32_t     error;      // POSIX error
} rfs_rsp_link_t;
=#
function rfs_link_ret(sock, ret, jl)
    if jl
	return_to_jl_client(sock, ret)
    else
	iob = IOBuffer()
	if !check_exception(iob, ret)
	    @debug("link() no error")
	    MsgPack.pack(iob, NO_ERROR)
	end
	@debug("link(): $(iob.data)")
	write(sock, UInt32(length(iob.data)), iob.data)
    end
end

#=
Unpack this
typedef struct rfs_arg_rename {
    rfs_file_op_t op;         // operation code
    cid_t         cid;        // channel id
    fid_t         old_dfid;   // old parent file id
    file_name_t   old_name;   
    fid_t         new_dfid;   // new parent file id
    file_name_t   new_name;  
} rfs_arg_rename_t;
=#
function rfs_rename_unpack(iob)
    cid = rfs_cid_unpack(iob)
    old_dfid = rfs_fid_unpack(iob)
    old_name = String(MsgPack.unpack(iob))
    new_dfid = rfs_fid_unpack(iob)
    new_name = String(MsgPack.unpack(iob))
    @debug("rename_unpack(): old_dir:$old_dfid old_name:$old_name new_dir:$new_dfid new_name:$new_name")
    return(OP_RENAME, (old_dfid, old_name, new_dfid, new_name), false, true, false)
end

# Unpack for julia
function rfs_rename_unpack(args::Tuple)
    # return (op, args, ro, ns, jl)
    return (OP_RENAME, args, false, true, true)
end

#=
Return this
typedef struct rfs_rsp_rename {
    __int32_t     error;      // POSIX error
} rfs_rsp_rename_t;
=#
function rfs_rename_ret(sock, ret, jl)
    if jl
        return_to_jl_client(sock, ret)
    else
        iob = IOBuffer()
        if !check_exception(iob, ret)
            MsgPack.pack(iob, NO_ERROR) # errno
        end
        write(sock, UInt32(length(iob.data)), iob.data)
    end
end

#=
Unpack this
typedef struct rfs_arg_unlink {
    rfs_file_op_t op;         // operation code
    cid_t         cid;        // channel id
    fid_t         p_fid;      // parent file id
    file_name_t   name;       // file name
} rfs_arg_unlink_t;
=#
function rfs_unlink_unpack(iob)
    cid = rfs_cid_unpack(iob)
    pfid = rfs_fid_unpack(iob)
    name = String(MsgPack.unpack(iob))
    @debug("unlink_unpack(): parent:$pfid name:$name")
    return(OP_UNLINK, (pfid, name), false, true, false)
end

# Unpack for julia
function rfs_unlink_unpack(args::Tuple)
    # return (op, args, ro, ns, jl)
    return (OP_UNLINK, args, false, true, true)
end

#=
Return this
typedef struct rfs_rsp_unlink {
    __int32_t     error;      // POSIX error
} rfs_rsp_unlink_t;
=#
function rfs_unlink_ret(sock, ret, jl)
    if jl
        return_to_jl_client(sock, ret)
    else
        iob = IOBuffer()
        if !check_exception(iob, ret)
            MsgPack.pack(iob, NO_ERROR) # errno
        end
        write(sock, UInt32(length(iob.data)), iob.data)
    end
end

#=
Unpack this
typedef struct rfs_arg_rmdir {
    rfs_file_op_t op;         // operation code
    cid_t         cid;        // channel id
    fid_t         p_fid;      // parent file id
    file_name_t   name;       // file name
} rfs_arg_rmdir_t;
=#
function rfs_rmdir_unpack(iob)
    cid = rfs_cid_unpack(iob)
    pfid = rfs_fid_unpack(iob)
    name = String(MsgPack.unpack(iob))
    @debug("rmdir_unpack(): parent:$pfid name:$name")
    return(OP_RMDIR, (pfid, name), false, true, false)
end

# Unpack for julia
function rfs_rmdir_unpack(args::Tuple)
    # return (op, args, ro, ns, jl)
    return (OP_RMDIR, args, false, true, true)
end

#=
Return this
typedef struct rfs_rsp_rmdir {
    __int32_t     error;      // POSIX error
} rfs_rsp_rmdir_t;
=#
function rfs_rmdir_ret(sock, ret, jl)
    if jl
        return_to_jl_client(sock, ret)
    else
        iob = IOBuffer()
        if !check_exception(iob, ret)
            MsgPack.pack(iob, NO_ERROR) # errno
        end
        write(sock, UInt32(length(iob.data)), iob.data)
    end
end

function rfs_read_unpack(iob)
    cid = rfs_cid_unpack(iob)
    fid = rfs_fid_unpack(iob)
    offset = UInt64(MsgPack.unpack(iob))
    size   = UInt64(MsgPack.unpack(iob))
    # return (op, args, ro, ns, jl)
    return (OP_READ, (fid, offset, size), true, false, false)
end

# Unpack for julia
function rfs_read_unpack(args::Tuple)
    # return (op, args, ro, ns, jl)
    return (OP_READ, args, true, false, true)
end

#=
Return this:
typedef struct rfs_rsp_read {
    __int32_t   error;      /* POISX error */
    __int64_t   size;       /* read size */
    char        buffer[];    /* read resp buffer */
} rfs_rsp_read_t;
=#
function rfs_read_ret(sock, ret, jl)
    if jl
        return_to_jl_client(sock, ret)
    else
        iob = IOBuffer()
        (data, ret_attr) = ret
        if !check_exception(iob, data)
            MsgPack.pack(iob, NO_ERROR) # errno
            MsgPack.pack(iob, UInt64(length(data)))
            MsgPack.pack(iob, data)
        end
        write(sock, UInt32(length(iob.data)), iob.data)
    end
end

function rfs_write_unpack(iob)
    cid = rfs_cid_unpack(iob)
    fid = rfs_fid_unpack(iob)
    offset = UInt64(MsgPack.unpack(iob))
    size   = UInt64(MsgPack.unpack(iob))
    buffer = MsgPack.unpack(iob)
    # return (op, args, ro, ns, jl)
    return (OP_WRITE, (fid, offset, size, buffer), false, false, false)
end

# Unpack for julia
function rfs_write_unpack(args::Tuple)
    # return (op, args, ro, ns, jl)
    return (OP_WRITE, args, false, false, true)
end

#=
Return this:
typedef struct rfs_rsp_write {
    __int32_t       error;      /* POISX error */
    __int64_t       size;       /* written size */
} rfs_rsp_write_t;
=#
function rfs_write_ret(sock, ret, jl)
    if jl
        return_to_jl_client(sock, ret)
    else
        iob = IOBuffer()
        (size, ret_attr) = ret
        if !check_exception(iob, ret) && !check_exception(iob, ret_attr)
            MsgPack.pack(iob, NO_ERROR) # errno
            MsgPack.pack(iob, UInt64(size))
            @debug("error= $NO_ERROR, size= $size")
        end
        write(sock, UInt32(length(iob.data)), iob.data)
    end
end

function rfs_readlink_unpack(iob)
    cid = rfs_cid_unpack(iob)
    fid = rfs_fid_unpack(iob)
    # return (op, args, ro, ns, jl)
    return (OP_READLINK, fid, true, true, false)
end

# Unpack for julia
function rfs_readlink_unpack(args::Tuple)
    # return (op, args, ro, ns, jl)
    return (OP_READLINK, args, true, true, true)
end

function rfs_readlink_ret(sock, ret, jl)
    if jl
        return_to_jl_client(sock, ret)
    else
        iob = IOBuffer()
        if !check_exception(iob, ret)
            MsgPack.pack(iob, NO_ERROR) # errno
            MsgPack.pack(iob, UInt64(length(ret)))
            MsgPack.pack(iob, ret)
        end
        write(sock, UInt32(length(iob.data)), iob.data)
    end
end


function rfs_mkfs_unpack(args::Tuple)
    # return (op, args, ro, ns, jl)
    return (OP_UTIL_MKFS, args, false, true, true)
end

function rfs_mkfs_ret(sock, ret, jl)
    if jl
        return_to_jl_client(sock, ret)
    end
end

function rfs_mount_unpack(args::Tuple)
    # return (op, args, ro, ns, jl)
    return (OP_MOUNT, args, false, true, true)
end

function rfs_mount_ret(sock, ret, jl)
    if jl
        return_to_jl_client(sock, ret)
    end
end

function rfs_checkpoint_unpack(args::Tuple)
    # return (op, args, ro, ns, jl)
    return (OP_CHK_PT, args, false, true, true)
end

function rfs_checkpoint_ret(sock, ret, jl)
    if jl
        return_to_jl_client(sock, ret)
    end
end

function rfs_syncpoint_unpack(args::Tuple)
    # return (op, args, ro, ns, jl)
    return (OP_SYNC_FS, args, false, true, true)
end

function rfs_syncpoint_ret(sock, ret, jl)
    if jl
        return_to_jl_client(sock, ret)
    end
end

function rfs_log_level_unpack(args::Tuple)
    # return (op, args, ro, ns, jl)
    return (OP_SET_LOG_LEVEL, args, true, true, true)
end

function rfs_log_level_ret(sock, ret, jl)
    if jl
        return_to_jl_client(sock, ret)
    end
end

# Lookup table for deserialization of incoming args and serialization
# of return values
const op_table = Dict(OP_LOOKUP   => (rfs_lookup_unpack, rfs_lookup_ret),
                      OP_READDIR  => (rfs_readdir_unpack, rfs_readdir_ret),
                      OP_CREATE   => (rfs_create_unpack, rfs_create_ret),
                      OP_MKNOD    => (rfs_mknod_unpack, rfs_create_ret),
                      OP_MKDIR    => (rfs_mkdir_unpack, rfs_mkdir_ret),
                      OP_RMDIR    => (rfs_rmdir_unpack, rfs_rmdir_ret),
                      OP_SYMLINK  => (rfs_symlink_unpack, rfs_symlink_ret),
                      OP_READLINK => (rfs_readlink_unpack, rfs_readlink_ret),
                      OP_GETATTRS => (rfs_getattrs_unpack, rfs_getattrs_ret),
                      OP_SETATTRS => (rfs_setattrs_unpack, rfs_setattrs_ret),
                      OP_LINK     => (rfs_link_unpack, rfs_link_ret),
                      OP_RENAME   => (rfs_rename_unpack, rfs_rename_ret),
                      OP_UNLINK   => (rfs_unlink_unpack, rfs_unlink_ret),
                      OP_READ     => (rfs_read_unpack, rfs_read_ret),
                      OP_WRITE    => (rfs_write_unpack, rfs_write_ret),
                      OP_UTIL_MKFS => (rfs_mkfs_unpack, rfs_mkfs_ret),
                      OP_MOUNT    => (rfs_mount_unpack, rfs_mount_ret),
                      OP_CHK_PT    => (rfs_checkpoint_unpack, rfs_checkpoint_ret),
                      OP_SYNC_FS   => (rfs_syncpoint_unpack, rfs_syncpoint_ret))

const ctl_op_table = Dict(OP_UTIL_MKFS => (rfs_mkfs_unpack, rfs_mkfs_ret),
                          OP_MOUNT    => (rfs_mount_unpack, rfs_mount_ret),
                          OP_CHK_PT    => (rfs_checkpoint_unpack, rfs_checkpoint_ret),
                          OP_SYNC_FS   => (rfs_syncpoint_unpack, rfs_syncpoint_ret),
                          OP_SET_LOG_LEVEL => (rfs_log_level_unpack, rfs_log_level_ret))
