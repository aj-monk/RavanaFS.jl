using ProgressMeter
using SHA
global cwd = fid_t(ROOT)
global cfs = rand(UInt128) # Uninitialized current working fs

function set_cfs(cid::id_t)
    global cfs = cid
end

function get_cfs()
    cfs
end

# ---------- Control Path ------------
"""
Create an fs on the given channel
"""
mkfs(cid::id_t) = mkfs(cid, false)

function mkfs(cid::id_t, recreate::Bool)
    super = rfs_client(id_t(0), OP_UTIL_MKFS, cid, recreate)
    if isa(super, Exception)
        return super
    end
    global cfs = super.cid
end

function mount(cid::id_t)
    super = rfs_client(id_t(0), OP_MOUNT, cid)
        if isa(super, Exception)
        println("Exception! $super")
        return false
    end
    global cfs = super.cid
end

function mount(name::String)
    cid::id_t = parse(id_t, name, 16)
    return mount(cid)
end


function checkpoint()
    ret = rfs_client(id_t(0), OP_CHK_PT, get_cfs())
    if isa(ret, Exception)
        dump(ret)
        return false
    end
end

function syncpoint()
    ret = rfs_client(id_t(0), OP_SYNC_FS, get_cfs())
    if isa(ret, Exception)
        dump(ret)
        return false
    end
end

function set_log_level(cid::id_t, level::Logging.LogLevel)
    ret = rfs_client(id_t(0), OP_SET_LOG_LEVEL, cid, level)
end

# ---------- Data Path ------------
function rfs_lookup(dfid::fid_t, fname::String)
    child = rfs_client(get_cfs(), OP_LOOKUP, dfid, fname)
    if isa(child, Exception)
        println("Exception! $(child)")
    end
    child
end

function rfs_rmdir(p_fid::fid_t, dname::String)
    ret = rfs_client(get_cfs(), OP_RMDIR, p_fid, dname)
    if isa(ret, Exception)
        println("Exception! $(ret)")
        return false
    end
end

function rfs_unlink(p_fid::fid_t, name::String)
    ret = rfs_client(get_cfs(), OP_UNLINK, p_fid, name)
    if isa(ret, Exception)
        println("Exception! $(ret)")
        return false
    end
end

function rfs_create(dfid::fid_t, fname::String, mask::UInt32, attr::FileAttr)
    ret = rfs_client(get_cfs(), OP_CREATE, dfid, fname, mask, attr)
    if isa(ret, Exception)
        #dump(ret)
        #println("Exception! $(child.msg)")
        return false
    end
    ret
end

function rfs_rename(old_dfid::fid_t, old_name::String, new_dfid::fid_t, new_name::String)
    ret = rfs_client(get_cfs(), OP_RENAME, old_dfid, old_name, new_dfid, new_name)
    if isa(ret, Exception)
        dump(ret)
        #println("Exception! $(child.msg)")
        return false
    end
end

function rfs_mkdir(dfid::fid_t, dname::String, mask::UInt32, attr::FileAttr)
    ret = rfs_client(get_cfs(), OP_MKDIR, dfid, mask, dname, attr)
    if isa(ret, Exception)
        dump(ret)
        #println("Exception! $(child.msg)")
        return false
    end
    ret
end

# The simple form
function rfs_mkdir(dname::String)
    rfs_mkdir(cwd, dname, UInt32(0), FileAttr())
end

function rfs_symlink(p_dfid::fid_t, fname::String, lpath::String, mask::UInt32, attr::FileAttr)
    ret = rfs_client(get_cfs(), OP_SYMLINK, p_dfid, mask, fname, attr, lpath)
    if isa(ret, Exception)
        dump(ret)
        #println("Exception! $(child.msg)")
        return false
    end
    ret
end

function rfs_link(p_fid::fid_t, fid::fid_t, lname::String)
    ret = rfs_client(get_cfs(), OP_LINK, p_fid, fid, lname)
    if isa(ret, Exception)
        dump(ret)
        #println("Exception! $(child.msg)")
        return false
    end
end

function rfs_getattr(fid::fid_t)
    attr = rfs_client(get_cfs(), OP_GETATTRS, fid)
    if isa(attr, Exception)
        dump(attr)
        #println("Exception! $(child.msg)")
        return attr
    end
    attr
end

function rfs_setattr(fid::fid_t, mask::UInt32, attr::FileAttr)
    ret = rfs_client(get_cfs(), OP_SETATTRS, fid, mask, attr)
    if isa(ret, Exception)
        dump(ret)
        #println("Exception! $(child.msg)")
        return ret
    end
    ret
end

function rfs_readdir(dfid::fid_t, whence::UInt64)
    ret = rfs_client(get_cfs(), OP_READDIR, dfid, whence)
    if isa(ret, Exception)
        dump(ret)
        return false
    end
    ret
end

function rfs_readdir(dfid::fid_t)
    return rfs_readdir(dfid, UInt64(0))
end

function rfs_write(fid::fid_t, offset::UInt64, len::UInt64, buf::Vector{UInt8})
    ret = rfs_client(get_cfs(), OP_WRITE, fid, offset, len, buf)
    if isa(ret, Exception)
        dump(ret)
        return false
    end
    ret
end

function rfs_read(fid::fid_t, offset::UInt64, len::UInt64)
    ret = rfs_client(get_cfs(), OP_READ, fid, offset, len)
    if isa(ret, Exception)
        dump(ret)
        return false
    end
    ret
end

function rfs_readlink(fid::fid_t)
    ret = rfs_client(get_cfs(), OP_READLINK, fid)
    if isa(ret, Exception)
        dump(ret)
        return false
    end
    ret
end

# ---------- Command line equivalents ------------

"""
    xcopy(path::String, fid::UInt128, blk_sz)
Copy from regular fs *path* to Ravana *fid* in *blk_sz* increments.

    xcopy(fid::UInt128, path::String, blk_sz)
Copy from Ravana *fid* to regular fs *path* in *blk_sz* increments.
"""
function xcopy(path::String, fid::UInt128, blk_sz)
    fattr = FileAttr()
    fattr.size = UInt64(0)
    rfs_setattr(fid, ATTR_SIZE, fattr) # Set file size to 0
    nblks = ceil(Int, stat(path).size / blk_sz)
    ios = open(path, "r")
    off::UInt64 = 0
    p = Progress(nblks, 1, "Copying: ")
    for i = 0:nblks-1
        buf = read(ios, blk_sz)
        (w, fattr) = Ravana.rfs_write(fid, off, UInt64(length(buf)), buf)
        off += w
        ProgressMeter.update!(p, Int(i+1))
    end
end

function xcopy(fid::UInt128, path::String, blk_sz)
    ios = open(path, "w")
    nblks = ceil(Int, stat(path).size / blk_sz)
    p = Progress(nblks, 1, "Copying: ")
    for i = 0:nblks
        (buf, fattr) = Ravana.rfs_read(fid, UInt64(i*blk_sz), UInt64(blk_sz))
        write(ios, buf)
        ProgressMeter.update!(p, Int(i+1))
    end
end

function print_dentry(e, attr)
    @printf("%16s 0x%32x %10d\n", e.name, e.fid, attr.size)
end

function ll()
    eof::UInt32 = 0
    whence::UInt64 = 0
    while eof != 1
        (dirs, eof) = rfs_readdir(cwd, whence)
        println("$(length(dirs)) entries found. eof = $eof")
        for i in dirs
            attr = rfs_getattr(i.fid)
            print_dentry(i, attr)
        end
        whence = dirs[end].whence
    end
end

function ll(fname::String)
    fattr = rfs_lookup(cwd, fname)
    isa(fattr, Exception) && return fattr
    @printf("%16s 0x%32x %10d\n", fname, fattr.ino, fattr.size)
end

function rfs_touch(fname::String)
    attr = rfs_create(cwd, fname, UInt32(0), FileAttr())
    attr.ino
end

function rfs_rm(fname::String)
    rfs_unlink(cwd, fname)
end

function rfs_cd(dirname::String)
    fattr = rfs_lookup(cwd, dirname)
    !isa(fattr, Exception) && (global cwd = fattr.ino)
end

function cksum(path::String)
    io = open(path, "r")
    (stat(io).size, bytes2hex(sha2_256(io)))
end

function cksum(fid::fid_t)
    fattr = rfs_getattr(fid)
    (buf, b) = rfs_read(fid, UInt64(0), fattr.size)
    (dec(fattr.size), bytes2hex(sha2_256(buf)))
end
