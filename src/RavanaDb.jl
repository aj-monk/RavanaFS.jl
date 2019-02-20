#= This file has code independent of any back end Db.
Code dependent on a particular db should be in a separate
file, one for each backend db.
=#


global fs_properties_db
global namespace_db = nothing
global data1_db
global data2_db

"""
The key-value stores used by Ravana.

fs_properties_db # distributed, full consistent | maps fs_id -> fs properties
remmote_oplog_db # distributed, eventual        | maps seq_num -> op
oplog_db         # local                        | maps seq_num -> op
namespace_db     # local                        | maps pinode,fname -> inode_num
                                                | maps inode_num -> Inode
data1_db         # local                        | maps block_num -> blk data
data2_db         # local                        | maps block_num -> blk data
"""
function rdb_init()
    global fs_properties_db = KVSRocksDB("fs_properties", base_dir())
    nothing
end

function rdb_exit()
    kvs_close(checkpoint_db)
    kvs_close(remote_oplog_db)
    kvs_close(oplog_db)
    kvs_close(namespace_db)
    kvs_close(data1_db)
    kvs_close(data2_db)
end
