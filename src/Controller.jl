# const BASE_DIR = "/opt/kinant/"
function  base_dir()
    b = getindex(ENV, "HOME") * "/.ravanafs/"
    stat(b).inode == 0 && Base.mkdir(b)
    try
        stat(b).inode == 0 && Base.mkdir(b)
    catch e
        error("Cannot access $(b). Perhaps you don't have permission?")
    end
    b
end

fs_base(cid) = base_dir() * hex(cid) * "/"

function get_src_path(component::String)
    function find_component(reg, arr)
        for i in arr
            (match(reg, i) != nothing) && (return i)
        end
        nothing
    end
    reg = Regex(component)
    # First search for component name in LOAD_PATH
    ((c = find_component(reg, LOAD_PATH)) != nothing) && (return c)

    # Search in current and 2 levels of parent directories
    ((c = find_component(reg, readdir("."))) != nothing) && (return "./$(component)")
    ((c = find_component(reg, readdir(".."))) != nothing) && (return "../$(component)")
    ((c = find_component(reg, readdir("../.."))) != nothing) && (return "../../$(component)")

    throw(RavanaInvalidArgException("Could'nt find component $(component)", ENOTNAM))
end

function controller_cleanup()
    csock = base_dir() * CSOCK
    rm(csock)
end

const CSOCK = "ControllerSock"
function controller()
    myid() != 1 && return
    sock = base_dir() * CSOCK
    @async begin
    server = nothing
    try
        server = listen(sock)
    catch e
        @error("Controller: listen error $(e)")
        @error("Check if another controller process is running. If not remove the file $(sock)")
        return
    end
    @debug("In controller listening on $(base_dir() * CSOCK)")
    while true
        try
            sock = accept(server)
            !isopen(sock) && @error("Error! Socket not open")
            (op, argv, ro, ns, jl) = get_opt(sock, ctl_op_table)
            @debug("Controller op = $op $argv")
            op == OP_UNKNOWN && continue

            execute_ctl_op(sock, op, argv, jl)
        catch e
            @error("Controller exception $(e)")
        end
    end
    end # Async task
end

function execute_ctl_op(sock, op, argv, jl)
    @async begin
        try
            ret = ctl_worker(op, argv)
            # Process and write return value to socket
            (in_func, out_func) = ctl_op_table[op]
            @debug("execute_ctl_op() returns $ret")
            out_func(sock, ret, jl)
        catch e
            process_exception(sock, op, e, jl, ctl_op_table)
        end
    end # Async task
end


mutable struct mntent_t
    ref::Int
    pid::Int
end

const mnttab = Dict{id_t, mntent_t}()

function ismounted(cid::id_t)
    try
        r = mnttab[cid]
        return true
    catch e
        return false
    end
end

"""
    get_ref(cid::id_t)
If the file system is mounted increment ref count on the FS and return it,
otherwise return 0. If an entry doesn't exist it is not created.
"""
function get_ref(cid::id_t)
    try
        r = mnttab[cid]
        r.ref += 1
        return r.ref
    catch e
        return 0
    end
end

function de_ref(cid::id_t)
    try
        r = mnttab[cid]
        r.ref == 0 && throw(RavanaInvalidArgException("Can't deref below 0", EINVAL))
        r.ref -= 1
        r.ref == 0 && delete!(mnttab, cid)
    catch e
        throw(RavanaInvalidArgException("Can't deref below 0", EINVAL))
    end
end

"""
    set_pid(cid, pid)
Set the pid on the given FS *cid* to *pid*. If the entry does not exist it
is created before the call returns.
"""
function set_pid(cid, pid)
    try
        r = mnttab[cid]
        r.pid != -1 && throw(RavanaInvalidArgException("PID already set for $(cid)", EEXIST))
        r.pid = pid
    catch e
        mnttab[cid] = mntent_t(1, pid)
        return 1
    end
end

function get_pid(cid)
    r = mnttab[cid]
    r.pid
end

function ctl_worker(op, argv)
    if op == OP_UTIL_MKFS
        return ctl_mkfs(argv[1], argv[2])
    elseif op == OP_MOUNT
        return ctl_mount(argv[1])
    elseif op == OP_SYNC_FS
        return ctl_sync_fs(argv[1])
    elseif op == OP_CHK_PT
        return ctl_checkpoint(argv[1])
    elseif op == OP_SET_LOG_LEVEL
        return ctl_set_log_level(argv[1], argv[2])
    end
end

function start_fs_proc(cid)
    # pid = addprocs(1; topology=:master_worker)[1]
    # set_pid(cid, pid)
    fsb = fs_base(cid)
    stat(fsb).size == 0 && mkdir(fsb)
    # m = Meta.parse(using RavanaFS)
    # fetch(@spawnat pid eval)
    # remotecall_fetch(init_dispatcher, pid, fsb)
    init_dispatcher(fsb)
end

function kill_fs_proc(cid)
    rmprocs(get_pid(cid))
    try
        r = mnttab[cid]
        remotecall_fetch(dispatch_cleanup, r.pid, fs_base(cid))
    catch e
    end
    delete!(mnttab, cid)
end

function ctl_mkfs(cid::id_t, recreate::Bool)
    println("In ctl_mkfs")
    get_ref(cid) > 0 && throw(RavanaInvalidArgException("Fs $(cid) already mounted", EEXIST))
    start_fs_proc(cid)
    sleep(1)
    ret = rfs_client(cid, OP_UTIL_MKFS, cid, recreate)
    isa(ret, Exception) && kill_fs_proc(cid)
    return ret
end

function ctl_mount(cid::id_t)
    get_ref(cid) > 0 && return true
    start_fs_proc(cid)
    ret = rfs_client(cid, OP_MOUNT, cid)
    isa(ret, Exception) && kill_fs_proc(cid)
    return ret
end

function ctl_set_log_level(cid::id_t, l)
    remotecall_fetch(Logging.configure, get_pid(cid), level=l)
end

function ctl_sync_fs(cid::id_t)
    rfs_client(cid, OP_SYNC_FS)
end

function ctl_checkpoint(cid::id_t)
    rfs_client(cid, OP_CHK_PT)
end
