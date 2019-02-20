using Ravana
using Logging

Logging.configure(level=INFO)
# -------- Unit tests --------

hex(n) = string(n, base=16)

const NCHANNELS = 4
global cid = Vector{Ravana.id_t}(NCHANNELS)

for i = 1:NCHANNELS
    cid[i] = Thimble.create_channel("x", "y")
end

# Ctrl path tests on different file systems
function test_fs1()
    info("test_fs1: Testing mkfs")
    for i = 1:length(cid)
        info("test_fs1: mkfs($(cid[i]))")
        typeof(mkfs(cid[i])) != UInt128 && return false
        prefix = hex(cid[i])
        create_files(prefix)
    end
    info("test_fs1: cant mkfs a mounted fs")
    for i = 1:length(cid)
        !isa(mkfs(cid[i]), Exception) && return false
    end
    info("test_fs1: each fs has separate namespace")
    for i = 1:length(cid)
        info("test_fs1: set_cfs($(cid[i]))")
        set_cfs(cid[i])
        prefix = hex(cid[i])
        info("test_fs1: check_files($prefix)")
        check_files(prefix) != true && return false
        info("test_fs1: check_files($prefix)")
        bad_prefix = hex(cid[((i+1)%length(cid))+1])
        check_files(bad_prefix) != false && return false
    end
    return true
end

# Create files and readdir
function test_fs2(;iter=100)
    set_cfs(cid[1])
    created = Dict{String, fid_t}()
    info("test_fs2: Creating files in $(cid[1])")
    for i=1:iter
        fname = "foo$i"
        attr = rfs_create(fid_t(Ravana.ROOT), fname, ATTR_MODE, FileAttr())
        created[fname] = attr.ino
    end

    (darray) = Ravana.rfs_readdir(fid_t(Ravana.ROOT), UInt64(0))
    received = Dict(darray[i].name => darray[i].fid for i = 1:length(darray))

    # assertion: all creates reflect in readdir
    info("test_fs2: checking created files exist")
    for i in keys(created)
        received[i] = created[i]
    end

    # assertion: cannot create files that exist
    info("test_fs2: cannot create files that exist")
    for i=1:iter
        fname = "foo$i"
        try
            rfs_create(fid_t(Ravana.ROOT), fname, ATTR_MODE, FileAttr())
        catch e
            if !isa(e, RavanaException)
                return false
            end
        end
    end
    true
end

function create_files(name::String; n=10)
    for i = 1:n
        rfs_touch("$(name)$(i)")
    end
end

function check_files(name::String; n=10)
    for i = 1:n
        isa(rfs_lookup(UInt128(1), "$(name)$(i)"), Exception) && return false
    end
    return true
end

function test_fs3()
    try
        info("test_fs3: mkfs($(cid[2]))")
        mkfs(cid[2])
    catch e
        info("test_fs3: fs $(cid[2]) exists")
    end
    info("test_fs3: creating 4096 files prefixed \"baba\" ")
    create_files("baba"; n=4096)
    info("checkpointing")
    checkpoint()
    info("Cloning channel")
    new_cid = Thimble.tdb_clone_channel(cid[2], UInt128(1))
    push!(cid, new_cid)
    info("restarting/restoring $(new_cid)")
    restart(new_cid, 1)
    info("mounting")
    mount(new_cid)
    info("checking files")
    check_files("baba"; n=4096)
end

function read_write_check(fid, bytes, offset, size)
    info("test_fs4: writing $size random bytes to $(hex(fid)) from offset $offset")
    (len, atr) = rfs_write(fid, UInt64(offset), UInt64(size), bytes)
    len != size && return false
    info("test_fs4:      reading $size bytes from $(hex(fid)) from offset $offset")
    (b, attr)  = rfs_read(fid, UInt64(offset), UInt64(size))
    info("Checking read == write")
    length(b) > size && println("read returned $(length(b)) > $size !!")
    if bytes[1:size] != b[1:size]
        println("mismatch detected")
        for i = 1:size
            if bytes[i] != b[i]
                println("Mismatch!: bytes[$i] = $(bytes[i]) != b[$i] = $(b[i])")
                return false
            end
        end
    end
    true
end

function test_fs4()
    try
        mkfs(cid[2])
        info("test_fs4: mkfs($(cid[2]))")
    catch e
        info("test_fs4: fs $(cid[2]) exists")
        set_cfs(cid[2])
    end
    attr = rfs_lookup(fid_t(Ravana.ROOT), "foo")
    if isa(attr, Exception)
        fid = rfs_touch("foo")
    else
        fid = attr.ino
    end

    a = rand(UInt8, (1<<20))
    # Aligned block
    !read_write_check(fid, a, 0, (Ravana.BLOCK_SIZE)) && (return false)
    # Unaligned block
    !read_write_check(fid, a, 4096+5, (Ravana.BLOCK_SIZE)) && (return false)
    # Unaligned bytes less than block size
    !read_write_check(fid, a, 8192+13, (35)) && (return false)
    # Unaligned bytes greater than block size
    !read_write_check(fid, a, (1<<14)+13, (Ravana.BLOCK_SIZE)+45) && (return false)

    #return true
    # TODO: Random offsets and sizes
    # Fix the pseudo random sequence for reproducability
    rng = srand(MersenneTwister(), 592)
    for i = 1:100
        offset = rand(rng, UInt64) & ((1 << 32) - 1)
        size   = rand(rng, UInt64) & ((1 << 16) - 1)
        !read_write_check(fid, a, offset, size) && (return false)
    end
    true
end

using Base.Test
function runtests_fs()
    @testset "Ravana file operations tests" begin
        @test test_fs1() == true
        @test test_fs2() == true
        @test test_fs3() == true
        #@test test_fs4() == true
        #@test test_fs5() == true
        #@test test_fs6() == true
        #@test test_fs7() == true
        #@test test_fs8() == true
        #@test test_fs9() == true
    end
end
