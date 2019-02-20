const ZERO_BLOCK = zeros(UInt8, BLOCK_SIZE)

function init_data_worker(id::Int)
    global worker_id = id
end

function data_worker(op, args, ro::Bool)
    if (op == OP_WRITE)
        return data_write(args[1], args[2], args[3], args[4])
    elseif (op == OP_READ)
        return data_read(args[1], args[2], args[3])
    elseif (op == OP_UTIL_MKFS || op == OP_MOUNT)
        return set_db(args[1])
    elseif (op == OP_UNLINK)
        return data_delete(args[1])
    end
end

function set_db(cid::id_t)
    global data_db = KVSRocksDB("data$(worker_id)", fs_base(cid))
    @debug("Set db to $data_db")
end

block(offset) = floor(UInt64, offset / BLOCK_SIZE)

"""
Delete blocks associated with an fid
"""
function data_delete(file_id::fid_t)
    first_blk = 0
    last_blk = (ns_getattr(file_id).size)/BLOCK_SIZE
    @debug("data_delete(): File $(hex(file_id)) first_blk: $first_blk last_blk: $last_blk")
    kvs_delete_range(data_db, (file_id, first_blk), (file_id, last_blk))
    #=
    for i = first_blk:(last_blk - 1)
        try
            kvs_delete(data_db, (file_id, i))
        catch e
            @debug("data_delete(): Exception at block $i")
        end
    end
    =#
end

"""
data_write(fid::fid_t, offset::UInt64, len::UInt64, data::Vector{UInt8})
Write *len* bytes of *data* to *fid* at *offset*.
"""
function data_write(fid::fid_t, offset::UInt64, len::UInt64, data::Vector{UInt8})
    lbn = Vector{Tuple{fid_t, UInt64}}(0)          # Array of logical block nums to write
    blks = Vector{Vector{UInt8}}(0)  # Array of data blocks to write

    if len == 0 return 0 end
    lbound = offset & ~(BLOCK_SIZE - 1) # Left block boundary (in bytes)
    rbound = (offset + len - 1) & ~(BLOCK_SIZE - 1) # Right block boundary
    first_block::UInt64 = block(lbound) # Left blk boundary in blocks
    last_block::UInt64 = block(rbound)  # Right block boundary in blocks
    block_boundary = 1                  # Moving block boundary marker in data
    #extended_len = rbound + BLOCK_SIZE - offset
    num_blks = last_block - first_block + 1#ceil(Int, extended_len/BLOCK_SIZE)
    @debug("offset=$offset len=$len lbound=$lbound rbound=$rbound num_blks=$num_blks")
    # Read leading block if write is partial
    if lbound != offset || lbound == rbound
        leading::Vector{UInt8} = copy(read_blocks(fid, first_block, first_block)[(fid, first_block)])
        cpy_first = offset - lbound + 1
        cpy_last = min(offset+len-lbound, BLOCK_SIZE)
        cpy_len = cpy_last - cpy_first
        @debug("leading[$cpy_first : $cpy_last] = data[1: $(cpy_len+1)]")
        leading[cpy_first:cpy_last] = data[1:cpy_len+1]
        # Create a batch of blocks
        push!(lbn, (fid, first_block))
        push!(blks, leading)
        block_boundary = cpy_len + 2
        first_block += 1 #(first_block == last_block ? first_block : first_block+1)
    end
    @debug("first_block=$first_block")
    # Blocks between leading and trailing need to be written as is
    if (rbound + BLOCK_SIZE != offset + len) && last_block > 0
        complete_last_blk = last_block - 1
    else
        complete_last_blk = last_block
    end
    for i = first_block:complete_last_blk
        @debug("i=$i first_block=$first_block last_block=$last_block")
        push!(lbn, (fid, i))
        push!(blks, view(data, block_boundary:(block_boundary+BLOCK_SIZE-1)))
        block_boundary += BLOCK_SIZE
    end
    # Read trailing block, if write is partial and is < eof
    if (rbound + BLOCK_SIZE != offset + len) && lbound != rbound
        trailing::Vector{UInt8} = copy(read_blocks(fid, last_block, last_block)[(fid, last_block)])
        @debug("length(trailing) = $(length(trailing))")
        cpy_first = 1
        cpy_last = offset + len - rbound
        cpy_len = cpy_last - cpy_first
        @debug("trailing[$cpy_first : $cpy_last] = data[$(len-cpy_len) : $(len)]")
        trailing[cpy_first:cpy_last] = data[len-cpy_len:len]
        push!(lbn, (fid, last_block))
        push!(blks, trailing)
    end

    kvs_write_batch(data_db, lbn, blks; raw_write=true)

    return len
    #return (lbn, blks)
end

function data_read(fid::fid_t, offset::UInt64, len::UInt64)
    if len == 0 return Vector{UInt8}() end
    lbound = offset & ~(BLOCK_SIZE - 1) # Left block boundary (in bytes)
    rbound = (offset + len - 1) & ~(BLOCK_SIZE - 1) # Right block boundary
    first_block::UInt64 = block(lbound) # Left blk boundary in blocks
    last_block::UInt64 = block(rbound)  # Right block boundary in blocks
    block_boundary = 1                  # Moving block boundary marker in data
    @debug("offset=$offset len=$len lbound=$lbound rbound=$rbound")

    blocks_read = read_blocks(fid, first_block, last_block)
    data = Vector{UInt8}(len)
    # Fill leading partial block
    if lbound != offset || lbound == rbound
        leading::Vector{UInt8} = blocks_read[(fid, first_block)]
        cpy_first = offset - lbound + 1
        cpy_last = min(offset+len-lbound, BLOCK_SIZE)
        cpy_len = cpy_last - cpy_first
        @debug("data[1: $(cpy_len+1)] = leading[$cpy_first : $cpy_last]")
        data[1:cpy_len+1] = leading[cpy_first:cpy_last]
        block_boundary = cpy_len + 2
        first_block += 1 #(first_block == last_block ? first_block : first_block+1)
    end
    # Fill data between leading and trailing blocks
    if (rbound + BLOCK_SIZE != offset + len) && last_block > 0
        complete_last_blk = last_block - 1
    else
        complete_last_blk = last_block
    end
    for i = first_block:complete_last_blk
        @debug("i=$i first_block=$first_block last_block=$last_block")
        block = blocks_read[(fid, i)]
        @debug("data[$block_boundary : $(block_boundary+BLOCK_SIZE-1)] = block[1 : $BLOCK_SIZE]")
        data[block_boundary:(block_boundary+BLOCK_SIZE-1)] = block[1:BLOCK_SIZE]
        block_boundary += BLOCK_SIZE
    end
    # Fill trailing partial block
    if (rbound + BLOCK_SIZE != offset + len) && lbound != rbound
        trailing::Vector{UInt8} = blocks_read[(fid, last_block)]
        @debug("length(trailing) = $(length(trailing))")
        cpy_first = 1
        cpy_last = offset + len - rbound
        cpy_len = cpy_last - cpy_first
        @debug("data[$(len-cpy_len) : $(len)] = trailing[$cpy_first : $cpy_last]")
        data[len-cpy_len:len] = trailing[cpy_first:cpy_last]
    end

    return data
end

"""
    read_blocks(fid::fid_t, first::UInt64, last::UInt64)
Reads blocks starting from logical block number(lbn) *first* and ending
with lbn *last*, both included. The block sizes are fixed at *BLOCK_SIZE*.

If a block does not exist *read_blocks()* returns ZERO_BLOCK, a statically
allocated block of binary zeros. Since ZERO_BLOCK is statically allocated
if the caller needs to modify a block, it has to make a copy of blocks
returned. read_blocks() does not check for eof and has no notion of files.
It is upto the caller to cross check the file's meta data.

The choice of returning zeros for blocks that are not found simplifies the
design of Ravana a great deal. The upper layers need not maintain a block
map for the file. The block map is implicitly defined by the underlying
data store.

Returns a dictionary: (fid, block #) => block_data::Vector{UInt8}(BLOCK_SIZE)
"""
function read_blocks(fid::fid_t, first::UInt64, last::UInt64)
    num_blks = last - first + 1
    (k, v, i) = kvs_get_many(data_db, (fid, first), (fid, last), num_blks; raw_read=true)
    # Convert to a Dict
    if i > 0
        d = Dict(zip(view(k, 1:i), view(v, 1:i)))
    else
        d = Dict((fid, first) => ZERO_BLOCK)
    end
    # Fill in missing blocks
    for i = first:last
        try
            d[(fid, i)]
        catch e
            d[(fid, i)] = ZERO_BLOCK
        end
    end
    return d
end

function offset_to_blocks(offset::UInt64, len::UInt64)
    ex_of = offest & ~(BLOCK_SIZE - 1) # Left extend to block boundary
    rbound = (offset + len + BLOCK_SIZE - 1) & ~(BLOCK_SIZE - 1) # Right extend
    ex_len = rbound - offset
    num_blks = len / BLOCK_SIZE
    @assert(num_blks * BLOCK_SIZE == len)
    blks = Vector{UInt64}(num_blks)
    return blks
end
