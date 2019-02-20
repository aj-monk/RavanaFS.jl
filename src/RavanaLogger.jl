using ProgressMeter

global remote_oplog_db
global oplog_db

# Stored log version number
const LOG_VERSION = UInt16(1)

# Logical Sequence Number (monotonically increasing)
global lsn = UInt64(0)

function init_log_db(cid::id_t)
    global remote_oplog_db = KVSRocksDB("remote_oplog", fs_base(cid))
    global oplog_db = KVSRocksDB("oplog", fs_base(cid))
end

function init_fs(fs_id)
    global current_fs = fs_id
    init_log_db(fs_id)
    global worker_id = 0
    data_worker(OP_MOUNT, fs_id, true) # Init data db
    recovery(fs_id)
    sync_server()     # Syncs fs at a given time interval
end

function log_it(op, payload)
    global lsn += 1
    try
        op == OP_SYNC_FS && return syncpoint(lsn, OP_SYNC_FS)
        op == OP_CHK_PT  && return checkpoint(lsn)
        op == OP_MOUNT && init_fs(payload[1])
        op == OP_UTIL_MKFS && init_fs(payload[1])
        kvs_put(oplog_db, lsn, (LOG_VERSION, op, payload))
    catch e
        return e
    end
    return lsn
end

function get_oplog_entry(lsn::UInt64)
    r = kvs_get(oplog_db, lsn)
#=
    if r == nothing
        throw(RavanaLoggerException("Could not fetch lsn $lsn"))
    end
    r
=#
end

function get_oplog_entries(first_lsn::UInt64, n::Integer)
    return assemble_oplog_entries(kvs_get_many(oplog_db, first_lsn, first_lsn+n-1, n))
end

function assemble_oplog_entries(args)
    args == nothing && throw(RavanaOplogException("Could not fetch entries", ENOENT))
    (k, v, n) = args
    return v[1:n]
end

function current_lsn()
    return lsn
end

# cp = check point = last backup to thimble
function get_last_cp(fs_id)
    (cp = kvs_get(oplog_db, (fs_id, "checkpoint"))) == nothing && return UInt64(0)
    return cp
end

function set_last_cp(fs_id, cp)
    kvs_put(oplog_db, (fs_id, "checkpoint"), cp)
end

# sp = sync point = last sync flush to persistent storage
function get_last_sp(fs_id)
    (sp = kvs_get(oplog_db, (fs_id, "syncpoint"))) == nothing && return UInt64(0)
    return sp
end

function set_last_sp(fs_id, sp)
    kvs_put(oplog_db, (fs_id, "syncpoint"), sp)
end

function setup_thimble()
    sid = Thimble.id_t(0)
    fs_id = get_current_fs()
    try
        sid = Thimble.tdb_create_stream(fs_id)
    catch e
        if isa(e, Thimble.StreamStateException)
            Thimble.tdb_commit_stream(fs_id, Thimble.tdb_get_stream(fs_id))
        end
        sid = Thimble.tdb_create_stream(fs_id)
    end
    sid
end

function sync_namespace(ts::DateTime)
    s = ns_get_super()
    s.sync_ts = ts
    ns_put_super(s)
    s
end

function sync_data(ts::DateTime)
    kvs_put_sync(data_db, (fid_t(THIMBLE_ARGS), UInt64(0)), ts)
end

"""
    syncpoint(sp_lsn)
All ops upto the op *sp_lsn* are persisted locally (sync point).
"""
function syncpoint(sp_lsn, op)
    get_last_sp(get_current_fs()) == sp_lsn && return sp_lsn
    ts = now(Base.Dates.UTC)
    sync_data(ts)
    sync_namespace(ts)
    # Note: sync oplog after namespace and data
    set_last_sp(get_current_fs(), sp_lsn)
    kvs_put_sync(oplog_db, sp_lsn, (LOG_VERSION, op, nothing))
    println("Sync point at $sp_lsn")
    return sp_lsn
end

"""
    checkpoint(cp_lsn)
All ops upto the given op *cp_lsn* are persisted locally (sync point) and backed
up to Thimble. A check point is also a sync point, but not the other way around.
"""
function checkpoint(cp_lsn)
    sid = setup_thimble()

    syncpoint(cp_lsn, OP_CHK_PT)  # Sync to persistent storage locally

    checkpoint_ns(sid)
    checkpoint_data(cp_lsn, sid)

    # Commit stream
    fs_id = get_current_fs()
    Thimble.tdb_commit_stream(fs_id, sid)
    set_last_cp(fs_id, cp_lsn)
    # Print stats
    (orig, saved, s) = Thimble.tdb_get_stats(fs_id, sid)
    @printf("\n%8s %11s %11s %11s\n", "Check_Pt", "Original_Sz", "Reduced_Sz", "Commit_Time")
    @printf("%8d %11d %11d %11s\n", sid, orig, (orig-saved), s.ts)

    return cp_lsn
end

function checkpoint_data(cp_lsn, sid)
    RUN = 100
    # Walk the list of op-log entries since last check point
    fs_id = get_current_fs()
    op_entry = last_cp = get_last_cp(fs_id)
    p = Progress(cp_lsn - last_cp, 1, "Checkpointing Data: ")
    while op_entry <= cp_lsn
        # get next RUN of entries
        ops = get_oplog_entries(op_entry, min(RUN, cp_lsn - op_entry))
        for i in ops
            # Push write operations to Thimble
            (ver, op, payload) = i
            if op == OP_WRITE
                (fid, off, len) = payload
                @debug("Updating Thimble stream for fid $fid at offset $off and length $len")
                vec = Vector{Thimble.extent_t}(1)
                (buf, err) = rfs_read(fid, off, len)
                ex = Thimble.extent_t(fid, off, UInt32(len), buf)
                vec[1] = ex
                Thimble.tdb_update_stream(fs_id, sid, vec)
            end
        end
        op_entry += RUN
        ProgressMeter.update!(p, Int(op_entry-last_cp+1))
    end
end

function checkpoint_ns(sid)
    fs_id = get_current_fs()
    cp_dir = fs_base(fs_id) * "/ns$(sid)"
    println("checkpoint $cp_dir ", stat(cp_dir))
    kvs_create_checkpoint(namespace_db, cp_dir)
    vec = Vector{Thimble.extent_t}()
    cwd = pwd()
    cd(fs_base(fs_id))
    Thimble.backup_to_thimble(fs_id, sid, "ns$(sid)", fid_t(NS_CHK_PT))
    cd(cwd)
end

function clone(cid, sid)
    ncid = Thimble.tdb_clone_channel(cid, sid)
    restart(ncid, sid)
    mkfs(ncid, true)
end

"""
    restart(cid, sid)
Refresh from Thimble the given cid, sid
"""
function restart(cid, sid)
    restart_ns(cid, sid)
end

function restart_ns(cid, sid)
    cwd = pwd()
    cp_dir = fs_base(cid)
    isdir(cp_dir) && throw(RavanaEExists("namespace exists", EEXIST))
    mkdir(cp_dir)
    cd(cp_dir)
    Thimble.restore_from_thimble(cid, sid, fid_t(NS_CHK_PT))
    println("restored ns$(sid)")
    mv("ns$(sid)", "namespace")
    # Fix super block
    db = KVSRocksDB("namespace", fs_base(cid))
    s = ns_get_super(db)
    s.pcid = s.cid
    s.cid = cid
    s.create_ts = now(Base.Dates.UTC)
    r = kvs_put_sync(db, fid_t(THIMBLE_ARGS), s)
    kvs_close(db)
end

"""
    recovery()
Recover this Ravana instance from oplog. It replays the oplog entries since last
sync point.
"""
function recovery(fs_id)
    PROBE_LENGTH = 1024
    sp::UInt64 = get_last_sp(fs_id)
    probe::UInt64 = sp + PROBE_LENGTH
    while get_oplog_entry(probe) != nothing
        probe += PROBE_LENGTH
    end
    global lsn = probe_oplog(probe - PROBE_LENGTH, probe)
    replay_oplog_entries(sp, lsn)
    true
end

# Binary search for last oplog entry
function probe_oplog(min, max)
    @assert(max >= min)
    @debug("Probing $min : $max")
    min == max && return min
    min == max-1 && get_oplog_entry(max) != nothing && return max
    min == max-1 && return min
    mid = floor(UInt64, (max+min+1)/2)
    get_oplog_entry(mid) == nothing && return probe_oplog(min, mid)
    return probe_oplog(mid, max)
end

"""
    replay_oplog_entries(sp, lsn)
Replay oplog in the range sp:lsn.
"""
function replay_oplog_entries(sp, lsn)
    # TBD. Not easy for oplog (Vs binary diff log)
    # Create an ordered list of modifications per fid
    # Simulate the changes in memory
    # Persist the simulated changes
end

const SYNC_INTERVAL = 60 # Seconds
function sync_server()
    @async begin
        while true
            sleep(SYNC_INTERVAL)
            syncpoint(lsn, OP_SYNC_FS)
        end # big while loop
    end  # async block
end
