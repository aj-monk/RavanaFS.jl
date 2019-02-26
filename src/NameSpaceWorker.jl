const SEED = UInt64(0xAB1D41D)  # A prime number

function init_ns_worker()
    #global namespace_db = KVSRocksDB("namespace")
end

function ns_worker(op, args, ro::Bool)
    if (op == OP_LOOKUP)
        return ns_lookup(args[1], args[2])
    elseif (op == OP_GETATTRS)
        return ns_getattr(args[1])
    elseif (op == OP_SETATTRS)
        return ns_setattr(args[1], args[2], args[3])
    elseif (op == OP_CREATE) || (op == OP_MKNOD)
        return ns_create(op, args[1], args[2], args[3], args[4], args[5])
    elseif (op == OP_MKDIR)
        return ns_mkdir(args[1], args[2], args[3], args[4], args[5])
    elseif ((op == OP_RMDIR) || (op == OP_UNLINK))
        return ns_remove(op, args[1], args[2])
    elseif (op == OP_LINK)
        return ns_link(args[1], args[2], args[3])
    elseif (op == OP_SYMLINK)
        return ns_symlink(args[1], args[2], args[3], args[4], args[5], args[6])
    elseif (op == OP_RENAME)
        return ns_rename(args[1], args[2], args[3], args[4])
    elseif (op == OP_READDIR)
        return ns_readdir(args[1], args[2])
    elseif (op == OP_READLINK)
        return ns_readlink(args[1])
    elseif (op == OP_UTIL_MKFS)
        return ns_mkfs(args[1], args[2])
    elseif (op == OP_GET_SUPER)
        return ns_get_super()
    elseif (op == OP_PUT_SUPER)
        return ns_put_super(args)
    elseif (op == OP_MOUNT)
        return ns_mount(args[1])
    end
end

"""
Lookup child_id using parent_id and fname, and return child
attribute structure.
"""
function ns_lookup(parent_id::fid_t, fname::String)
    @debug("ns_lookup(): parent:$parent_id, name:$fname")
    try
        ret = kvs_get(namespace_db, (parent_id, hash(fname, SEED), fname))
        if (ret != nothing)
            @debug("ns_lookup(): File found fid:$ret")
            return ns_getattr(ret)
        else
            return RavanaInvalidIdException("File: $fname not found", ENOENT)
        end
    catch e
        return e
    end
end

function ns_readdir(parent_id::fid_t, whence::UInt64)
    #try
        # Check if parent exists
        if kvs_get(namespace_db, parent_id) == nothing
            return RavanaInvalidIdException("Invalid parent_id $parent_id", EBADF)
        end
        first = (parent_id, whence, "\U0")
        last  = (parent_id, UInt64(0xffffffffffffffff), "\Uffff")
        @debug("$namespace_db, $first, $last, 1024, inc_first=false")
        dir = assemble_dirent(kvs_get_many(namespace_db, first, last, 1024, inc_first=false))
        # return (dir, eof status)
        return (dir, length(dir)<1024 ? UInt32(1) : UInt32(0))
    #catch e
    #    return e
    #end
end

"""
Read a symbolic link and return linkpath
"""
function ns_readlink(fid::fid_t)
    @debug("ns_readlink(): File id $fid")
    try
        # Check if file exists
        ret = kvs_get(namespace_db, fid)
        if (ret == nothing)
            return RavanaInvalidException("File $fid doesn't exist", ENOENT)
        elseif !isa(ret, Tuple)
            return RavanaInvalidException("Inode entry for $fid is not a Tuple, not a symlink", EINVAL)
        else
            return ret[2]
        end
    catch e
        return e
    end
end
"""
Create a new file in this namespace and return it's attribute structure
This function handles mknod() as well.
"""
function ns_create(op::Int32, parent_id::fid_t, child_id::fid_t, fname::String, mask::UInt32, attr::FileAttr)
    @debug("ns_create(): parent:$parent_id child:$child_id name:$fname")
    new_attr = FileAttr()
    try
        # Check if parent exists
        parent_attr = ns_getattr(parent_id)
        if isa(parent_attr, Exception)
            return RavanaInvalidException("Invalid parent_id $parent_id", ENOENT)
        end

        # Check if a file with the name already exists
        if (kvs_get(namespace_db, (parent_id, hash(fname, SEED), fname)) != nothing)
            return RavanaEExists("File $fname exists in dir $parent_id", EEXIST)
        end

        # Add entries
        setattr(new_attr, attr, mask)
        new_attr.ino = child_id
        new_attr.dev = cur_cid
        if (op == OP_MKNOD)
            new_attr.mode = new_attr.mode | (attr.mode & S_IFMT)
            if(attr.rdev != 0)
                new_attr.rdev = attr.rdev
            end
        else
            new_attr.mode = new_attr.mode | S_IFREG
        end
        new_attr.links = 1
        kvs_put(namespace_db, child_id, new_attr) # Inode table

        #TODO: change this hash to our own implementation as julia's hash
        # implementation may change in a new Julia version
        kvs_put(namespace_db, (parent_id, hash(fname, SEED), fname), child_id) # Dir entry

        # Bump up parent directory entry count
        parent_attr.size += 1
        # Update mtime and ctime for parent directory
        parent_attr.mtime = TimeSpec()
        parent_attr.ctime = TimeSpec()
        kvs_put(namespace_db, parent_id, parent_attr)
    catch e
        return e
    end
    return new_attr
end

"""
Create symbolic link for a file
"""
function ns_symlink(parent_dfid::fid_t, child_id::fid_t, fname::String, lpath::String, mask::UInt32, attr::FileAttr)
    @debug("ns_symlink(): parent:$parent_dfid child:$child_id name:$fname link_path=$lpath")
    new_attr = FileAttr()
    try
        # Check if parent exists
        parent_attr = ns_getattr(parent_dfid)
        if isa(parent_attr, Exception)
            return RavanaInvalidException("Invalid parent_id $parent_dfid", ENOENT)
        end

        # Check if a file with the same name already exists
        if (kvs_get(namespace_db, (parent_dfid, hash(fname, SEED), fname)) != nothing)
            return RavanaInvalidException("File $fname already exists", EEXIST)
        end

        # Add entries
        setattr(new_attr, attr, mask)
        new_attr.ino = child_id
        new_attr.dev = cur_cid
        #@set_flag(new_attr.mode, S_IFLNK)
        new_attr.mode = new_attr.mode | S_IFLNK
        new_attr.links = 1
        new_attr.size = length(lpath)
        # To save having to write() we insert the link_path as part of the inode table
        kvs_put(namespace_db, child_id, (new_attr, lpath)) # Inode table

        #TODO: change this hash to our own implementation as julia's hash
        # implementation may change in a new Julia version
        kvs_put(namespace_db, (parent_dfid, hash(fname, SEED), fname), child_id)

        # Bump up parent directory entry count
        parent_attr.size += 1
        # Update mtime and ctime for parent directory           
        parent_attr.mtime = TimeSpec()
        parent_attr.ctime = TimeSpec()
        kvs_put(namespace_db, parent_dfid, parent_attr)
    catch e
        return e
    end
    return new_attr
end

"""
Rename a file
"""
function ns_rename(old_dfid::fid_t, old_name::String, new_dfid::fid_t, new_name::String)
    @debug("ns_rename(): olddir:$old_dfid old_name:$old_name newdir:$new_dfid new_name:$new_name")
    try
        # Check if parent exists
        old_dir_attr = ns_getattr(old_dfid)
        if isa(old_dir_attr, Exception)
            return RavanaInvalidException("Invalid old dir $old_dfid", ENOENT)
        end

        # Check if the file to be renamed exists
        file_id = kvs_get(namespace_db, (old_dfid, hash(old_name, SEED), old_name))
        if (file_id == nothing)
            return RavanaInvalidException("File to rename doesn't exist $fid", ENOENT)
        end

        # the old directory entry has to go either way
        kvs_delete(namespace_db, (old_dfid, hash(old_name, SEED), old_name))

        if (old_dfid != new_dfid)
            # Check that the new directory is valid
            new_dir_attr = ns_getattr(new_dfid)
            if isa(new_dir_attr, Exception)
                return RavanaInvalidException("Invalid new dir $new_dfid", ENOENT)
            end
            # Update new directory entry and count
            kvs_put(namespace_db, (new_dfid, hash(new_name, SEED), new_name), file_id)
            new_dir_attr.size += 1
            kvs_put(namespace_db, new_dfid, new_dir_attr)
            # reduce directory entry count of old dir
            old_dir_attr.size -= 1
            kvs_put(namespace_db, old_dfid, old_dir_attr)
        else
            # Insert directory entry with new name
            kvs_put(namespace_db, (old_dfid, hash(new_name, SEED), new_name), file_id)
        end
    catch e
        return e
    end
end

"""
Create hard link for a file
"""
function ns_link(parent_did::fid_t, link_to::fid_t, link_name::String)
    @debug("ns_link(): parent $parent_did, linkto $link_to, link name $link_name")
    try
        # Check if the parent directory exists
        parent_attr = ns_getattr(parent_did)
        if isa(parent_attr, Exception)
            return RavanaInvalidException("Invalid parent dir $parent_did", ENOENT)
        end

        # Check if file to link to exists
        if (kvs_get(namespace_db, link_to) == nothing)
            return RavanaInvalidException("File to link to doesn't exist $link_to", ENOENT)
        end

        # Add hard link to directory entry
        kvs_put(namespace_db, (parent_did, hash(link_name, SEED), link_name), link_to)

        # Bump up link count of the file linked to
        cur_attr = ns_getattr(link_to)
        cur_attr.links += 1
        kvs_put(namespace_db, link_to, cur_attr)

        # Bump up parent directory entry count
        parent_attr.size += 1
        # Update mtime and ctime for parent directory           
        parent_attr.mtime = TimeSpec()
        parent_attr.ctime = TimeSpec()
        kvs_put(namespace_db, parent_did, parent_attr)
    catch e
        return e
    end
end

"""
Create a new directory in this namespace and return it's attribute structure
"""
function ns_mkdir(parent_did::fid_t, child_did::fid_t, dname::String, mask::UInt32, attr::FileAttr)
    @debug("ns_mkdir(): parentdir:$parent_did newchilddir:$child_did dirname:$dname")
    child_dir_attr = FileAttr()
    try
        # Check if parent directory exists
        parent_attr = ns_getattr(parent_did)
        if isa(parent_attr, Exception)
            return RavanaInvalidException("Invalid parent_id $parent_id", ENOENT)
        end

        # Check if a directory with the same name exists
        if (kvs_get(namespace_db, (parent_did, hash(dname, SEED), dname)) != nothing)
            return RavanaEExists("Directory $dname already exists in dir $parent_did", EEXIST)
        end

        # Add entries
        setattr(child_dir_attr, attr, mask)
        child_dir_attr.ino = child_did
        child_dir_attr.dev = cur_cid
        #@set_flag(child_dir_attr.mode, S_IFDIR)
        child_dir_attr.mode = child_dir_attr.mode | S_IFDIR
        child_dir_attr.size = 2        # Num of entries in this directory
        child_dir_attr.links = 2
        kvs_put(namespace_db, child_did, child_dir_attr) # Inode table

        #TODO: change this hash to our own implementation as julia's hash
        # implementation may change in a new Julia version
        # Dir entry in the parent dir
        kvs_put(namespace_db, (parent_did, hash(dname, SEED), dname), child_did) 
        # Add . and .. in the newly created directory
        kvs_put(namespace_db, (child_did, hash(".", SEED), "."), child_did)
        kvs_put(namespace_db, (child_did,  hash("..", SEED), ".."), parent_did)

        # Bump up parent directory entry count
        parent_attr.size += 1
        parent_attr.links += 1
        # Update mtime and ctime for parent directory           
        parent_attr.mtime = TimeSpec()
        parent_attr.ctime = TimeSpec()
        kvs_put(namespace_db, parent_did, parent_attr)
    catch e
        return e
    end
    return child_dir_attr
end

"""
Remove a file/directory from a namespace
"""
function ns_remove(op::Int32, p_fid::fid_t, name::String)
    @debug("ns_remove(): parentdir:$p_fid name:$name")
    try
        # Check if parent directory exists
        parent_attr = ns_getattr(p_fid)
        if isa(parent_attr, Exception)
            return RavanaInvalidException("Invalid parent_id $p_fid", ENOENT)
        end

        # Check if file to delete exists
        file_id = kvs_get(namespace_db, (p_fid, hash(name, SEED), name))
        if (file_id == nothing)
            return RavanaInvalidException("$name doesn't exist in $p_fid", ENOENT)
        end

        if (op == OP_RMDIR)
            dir_attr = ns_getattr(file_id)
            if (dir_attr.size > 2)
                return RavanaInvalidException("Directory $name is not empty!", ENOTEMPTY)
            end
        end

        # Remove entry from parent, and reduce directory entry count
        kvs_delete(namespace_db, (p_fid, hash(name, SEED), name))
        parent_attr.size -= 1
        if (op == OP_RMDIR)
            parent_attr.links -= 1
        end
        # Update mtime and ctime for parent directory           
        parent_attr.mtime = TimeSpec()
        parent_attr.ctime = TimeSpec()
        kvs_put(namespace_db, p_fid, parent_attr)

        # TODO: make the remaining asynchronous routines
        # Reduce the link count or remove data associated with the file
        if (op == OP_UNLINK)
            file_attr = ns_getattr(file_id)
            if file_attr.links > 1
                file_attr.links -= 1
                kvs_put(namespace_db, file_id, file_attr)
                return nothing
            else
                ret = data_worker(op, file_id, false)
            end
        end

        # Finally remove the inode for file/dir
        kvs_delete(namespace_db, file_id)
    catch e
        return e
    end
end

function ns_getattr(fid::fid_t)
    try
        @debug("ns_getattr(): file $fid")
        if (value= kvs_get(namespace_db, fid)) == nothing
            return RavanaInvalidIdException("Invalid fid $fid", ENOENT)
        end
        if (isa(value, Tuple))
            @debug("ns_getattr(): Symlink found. attr: $value[1] lpath: value[2]")
            attr = value[1]
        else
            attr = value
        end
        return attr
    catch e
        return e
    end
end

function ns_setattr(fid::fid_t, mask::UInt32, attr::FileAttr)
    try
        if (kvs_get(namespace_db, fid)) == nothing
            return RavanaInvalidIdException("Invalid fid $fid", EBADF)
        end
        cur_attr = ns_getattr(fid)
        setattr(cur_attr, attr, mask)
        kvs_put(namespace_db, fid, cur_attr)
    catch e
        return e
    end
    return true
end

function ns_get_super()
    ns_get_super(namespace_db)
end

function ns_get_super(db)
    r = kvs_get(db, fid_t(THIMBLE_ARGS))
    if (r == nothing) return nothing end
    return r
end

function ns_mount(cid::id_t)
    global namespace_db = KVSRocksDB("namespace", fs_base(cid))
    global cur_cid = cid
    s = ns_get_super()
    s == nothing && return RavanaUnexpectedFailureException("no fs found", ENODATA)
    s.cid != cid && return RavanaUnexpectedFailureException("$cid != $(s.cid)", ENODATA)
    #recovery(cid) # Run recovery
    s
end

function ns_put_super(super)
    s = ns_get_super()
    if s.cid != super.cid
        return RavanaInvalidIdException("cid in super is immutable", EINVAL)
    end
    r = kvs_put_sync(namespace_db, fid_t(THIMBLE_ARGS), super)
    if (r == nothing) return nothing end
    return r
end

function ns_mkfs(cid::id_t)
    ns_mkfs(cid, false)
end

function ns_mkfs(cid::id_t, recreate::Bool)
    # TODO: check if we have permission to access given channel
    # TODO: check if there already exists an fs on channel
    # TODO: check if the channel is at sid=0
    # set location of db to <base_dir>/cid/properties_db
    pcid = id_t(0)
    global namespace_db = KVSRocksDB("namespace", fs_base(cid))
    if (s = ns_get_super()) != nothing
        if recreate == false
            return RavanaEExists("File system exists on given channel $cid", EEXIST)
        end
    end
    global cur_cid = cid
    db = namespace_db
    # Write fs stuff to (hidden) inode 2
    super = RavanaSuper(FS_VERSION, pcid, cid, id_t(1), now(Dates.UTC),
                        Millisecond(0), Millisecond(0))
    kvs_put(db, fid_t(THIMBLE_ARGS), super)
    recreate && return super

    attr = FileAttr()
    #@set_flag(attr.mode, S_IFDIR)
    attr.mode = attr.mode | S_IFDIR
    # Root is a special child
    attr.mode = attr.mode | 0o755
    attr.links = UInt32(2)
    attr.size = UInt64(2)
    attr.dev = cid
    attr.ino = fid_t(ROOT)
    kvs_put(db, fid_t(ROOT), attr)
    kvs_put(db, (fid_t(ROOT), hash(".", SEED), "."), fid_t(ROOT))
    kvs_put(db, (fid_t(ROOT),  hash("..", SEED), ".."), fid_t(ROOT))
    #kvs_put(db, (fid_t(ROOT), "/"), fid_t(ROOT))
    return super
end

function assemble_dirent(input)
    (k, v, n) = input
    @debug("found $n dir entries")
    dir = Vector{Dentry}(undef, n)
    h = UInt64(0)
    for i = 1:n
        (p, h, name) = k[i]
        if (isa(v[i], Tuple))
            file_id, lpath = v[i]
        else
            file_id = v[i]
        end
        # Return the hash/whence of the directory entry that is next
        dir[i] = Dentry(name, file_id, h+1)
    end
    return dir
end

"""
setattr(fattr::FileAttr, attr::FileAttr, mask::UInt16)
Set the attributes from *attr* in *fattr* based on *mask*.
"""
function setattr(fattr::FileAttr, attr::FileAttr, mask::UInt32)
    if is_flag(mask, ATTR_MODE)
        # We want to zero out the lowest three octals
        fattr.mode &= 0xFFFFFE00
        fattr.mode |= attr.mode
    end
    if is_flag(mask, ATTR_UID)
        fattr.uid = attr.uid
    end
    if is_flag(mask, ATTR_GID)
        fattr.gid = attr.gid
    end
    if is_flag(mask, ATTR_SIZE)
        fattr.size = attr.size
    end
    if is_flag(mask, ATTR_ATIME)
        fattr.atime = attr.atime
    end
    if is_flag(mask, ATTR_MTIME)
        fattr.mtime = attr.mtime
    end
    if is_flag(mask, ATTR_CTIME)
        fattr.ctime = attr.ctime
    else
        #Update ctime if not specified by user
        fattr.ctime = TimeSpec()
    end
end
