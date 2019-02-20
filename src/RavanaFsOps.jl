# File system operations



"""
A directory is implemented as a sequence of 1 Mb blocks. 1 Mb is considered
monstrous in general purpose file systems, but Ravana being a monster gets by
with monstrosity. Lets look at the drawbacks of a large block size:
1. Loading a block consumes memory.
   The cost of memory has decreased that 1 Mb is no longer a constraint. Even
   a smart phone has many Gbs of memory. Further, the 1 Mb block will be
   compressed, so the actual memory consumed is likely to be much lesser.
2. Network transfer costs are high.
   The block is compressed, so the xfer costs can be lower than designs with
   a smaller block size.
3. Directory search bring in unnecessary entries into memory.
   This is not a B-Tree layout. It is a plain old sequential layout. We
   traverse the directory only for readdir. We maintain an index outside
   the directory for fast lookup.
4. Update costs are high.
   This is true. But updates occur only during snapshotting. And we want the
   simplest design to get us by (for now).
The advantage of a large directory block is that we are optimizing for 99%
of readdir cases. As mentioned we don't traverse the directory for lookup.
And, a larger block size allows for better compression.

NOTE: If this design becomes a constraint consider using a Linear Hash layout.
      https://en.wikipedia.org/wiki/Linear_hashing
"""
function mkdir(dhandle::Fhandle, fname::String)
    if dhandle.ino.ftype != DIR
        throw(RavanaInvalidHandleException("Not a directory"))
    end
    dentry::Dentry = Dentry(fname, rand(fid_t))
    ino::Inode = Inode(dentry.fid, 0, DIR)
    insert_dentry(dhandle, dentry)
end

function mk_root(cid::id_t)
    root::Dict{String, fid_t} = Dict("." => ROOT, ".." => ROOT)
    if Thimble.get_stream("TODO: fix cred", cid) != 1
        throw(RavanaInvalidIdException("mk_root() needs to be called on stream 1", EINVAL))
    end
    val = byte_array(root)
    Thimble.put("TODO: fix cred", cid, id_t(1), UInt128(ROOT), val)
end

#=
function mk_root(cid::id_t)
    dot::Vector{Dentry} = [Dentry(".", ROOT), Dentry("..", ROOT)]
    block::DBlock = DBlock(DBlockHeader(), dot)
    #block::DBlock = DBlock(2)
    #push!(block.entries, Dentry("..", ROOT))

    if Thimble.get_stream("TODO: fix cred", cid) != 1
        throw(RavanaInvalidIdException("mk_root() needs to be called on stream 1"))
    end
    val = byte_array(block)
    Thimble.put("TODO: fix cred", cid, id_t(1), UInt128(ROOT), val)
end
=#

# -------- Helper functions --------
"""
    insert_dentry(dentry::Dentry)
"""
function insert_dentry(dhandle::Fhandle, dentry::Dentry)

end

# -------- Unit tests --------
"""
The function that calls test_error(exp) returns 'false' if expression
*exp* evaluates to false
"""
macro test_error(exp)
    quote
        if ( $exp == false )
            println("Test Error! in $exp")
            return false
        end
    end
end

"""
Basic mk_root()
"""
function test_ravana1()
    cid = create_channel("cred", "prop")
    # Cannot create root when stream id < 1
    try
        mk_root(cid)
    catch e
        @test_error(isa(e, RavanaInvalidIdException))
    end
    # Able to create root when stream id == 1
    sid = create_stream("cred", cid)
    mk_root(cid)
    commit_stream("cred", cid, sid)
    # Cannot create root when stream id > 1
    sid = create_stream("cred", cid)
    try
        mk_root(cid)
    catch e
        @test_error(isa(e, RavanaInvalidIdException))
    end
    return true
end

using Base.Test
function runtests_ravana()
    @testset "Ravana tests" begin
        @test test_ravana1() == true
        #@test test_ravana2() == true
        #@test test_ravana3() == true
        #@test test_ravana4() == true
        #@test test_ravana5() == true
        #@test test_ravana6() == true
        #@test test_ravana7() == true
        #@test test_ravana8() == true
        #@test test_ravana9() == true
    end
end
