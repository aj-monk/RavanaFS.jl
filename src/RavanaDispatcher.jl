using MsgPack

@enum server_state ACTIVE QUIESING INACTIVE

const DSOCK = "RavanaSocket"

global current_fs = 0

function init_dispatcher()
    dispatch_server(".")
end

function init_dispatcher(base::String)
    dispatch_server(base)
end

"""
    rfs_client()
This is the dispatcher client for sending ops to the
dispatch_server. Use this function to send ops from
within Julia.

If *cid* == 0 then the client talks to the controller.
If *cid* is anything else the client talks to the given
fs's process.
"""
function rfs_client(cid::id_t, op::Int32, argv...)
    bytes = byte_array((op, argv))
    size = UInt32(length(bytes))
    version = UInt16(RFS_PROTO_VERSION)
    flags = UInt16(RFS_JULIA_CLIENT)
    endpoint = (cid == 0) ? base_dir() * "$(CSOCK)" : fs_base(cid) * "$(DSOCK)"
    println("rfs_client: writing to $(endpoint)")
    client = connect(endpoint)
    println("rfs_client connected")

    write(client, size, version, flags, bytes)
    ret_size = read(client, Int)
    ret = array_to_type(read(client, ret_size))
    close(client)
    ret
end

"""
    process_exception(sock, op, e, lookup_table)
Generate the appropriate error number given the op and the exception.
"""
function process_exception(sock, op, e, jl, lookup_table)
    #error("Error! $(op) caused exception $(e)")
    op == OP_UNKNOWN && return
    (in_func, out_func) = lookup_table[op]
    out_func(sock, e, jl)
end


function process_preamble(h::UInt64)
    size    = UInt32(h & 0xffffffff)
    version = UInt16((h >> 32) & 0xffff)
    flags   = UInt16((h >> 48) & 0xffff)
    @debug("size=$size version=$version flags=$flags", " ", string(h, base=16))
    (size, version, flags)
end

function get_opt(sock, lookup_table)
    try
        (size::UInt32, version::UInt16, flags::UInt16) = process_preamble(read(sock, UInt64))
        if version != RFS_PROTO_VERSION
            throw(RavanaProtoException("Unsupported version $(version)", EPROTO))
        end

        if flags & RFS_JULIA_CLIENT == RFS_JULIA_CLIENT
            (op, argv) = @pcount("read_sock", array_to_type(read(sock, size)))
            (in_func, out_func) = lookup_table[op]
            return in_func(argv)
        else
            iob = IOBuffer(read(sock, size))
            seek(iob, 0)
            op = MsgPack.unpack(iob)
            (in_func, out_func) = lookup_table[op]
            return in_func(iob)
        end
    catch e
        println("getopt exception $(e)")
        process_exception(sock, OP_UNKNOWN, e, false, op_table)
        return (OP_UNKNOWN, nothing, true, true, false)
    end
end

get_dsock(base::String) = base * "/" * DSOCK

function dispatch_cleanup(base::String)
    rm(get_dsock(base); force = true)
end

"""
    dispatch_server()

The "dispatcher" process routes requests to other methods that do the
real work. The dispatcher is not multi-threaded, so care must be taken
that it does not block in the OS kernel for anything. If it does, then
any request can block all other requests even if the worker processes
are free.

The dispatcher is made non-blocking by its use of Julia tasks (super light
weight schedulable entities). The flow is as follows:
1. dispatch_server()
   This is started by the module init function on the master process. It
   opens a socket and waits for clients to send requests.
2. log_task()
   A task is created for each new request triggered from dispatch_server().
   The task logs the operation using the logger and on completion of logging
   executes the operation through a method dispatch table.
   The result of the execution is returned in the socket.
"""
function dispatch_server(base::String)
    println("In dispatch_server")
    stat(get_dsock(base)).inode != 0 && throw(RavanaEExists("Data path socket exists $(base)", EEXIST))

    @async begin
        server = listen(get_dsock(base))
        @debug("Dispatcher waiting on $(get_dsock(base))")
        println("Dispatcher waiting on $(get_dsock(base))")
        while true
            sock = accept(server)
            if isopen(sock) != true
                @error("Error! Socket not open")
                # return error
            end

            # op   | Int32 | op to execute
            # argv | Tuple | arguments to op
            # ro   | Bool  | op is read-only
            # ns   | Bool  | op operates on namespace only
            # jl   | Bool  | client is Julia
            (op, argv, ro, ns, jl) = @pcount("get_opt_call", get_opt(sock, op_table))
            @debug("op=$op")
            if op == OP_UNKNOWN continue end

            try
                if current_fs == 0 && op != OP_UTIL_MKFS && op != OP_MOUNT
                    @error("Error: channel not initialized")
                    throw(RavanaInvalidArgException("channel not initialized", EACCESS))
                end

                if current_fs != 0 && op == OP_MOUNT
                    @error("Fs already mounted")
                    throw(RavanaInvalidArgException("Fs already mounted", EBUSY))
                end

                log_task(sock, op, argv, ro, ns, jl)
            catch e
                process_exception(sock, op, e, jl, op_table)
            end
        end  # while loop
    end  # async block

    while stat(get_dsock(base)).inode == 0
        sleep(0.1)
    end
end

"""
    log_task(sock, op, args, ro::Bool, ns::Bool)
Create a task that sends the op to the logger process and then sends
it to for execution.
"""
function log_task(sock, op, args, ro::Bool, ns::Bool, jl::Bool)
    @async begin
        if ro == false #Log only modifying ops
            if op == OP_WRITE # do not log data locally
                (fid, offset, len, data) = args
                seq_no = log_it(op, (fid, offset, len))
            else
                seq_no = log_it(op, args)
            end
            @debug("lsn = $seq_no")
            # Some ops are executed by logger above, so return to client
            if op == OP_CHK_PT || op == OP_SYNC_FS
                (in_func, out_func) = op_table[op]
                out_func(sock, (seq_no), jl)
                return
            end
        end
        @pcount("execute_call", execute(sock, op, args, ro, ns, jl))
    end # @async block, aka Task
end

"""
    execute(sock, op, args, ro::Bool, ns::Bool)
Sends the op to a worker for execution and writes the returned
value to the socket.
"""
function execute(sock, op::Int32, args, ro::Bool, ns::Bool, jl::Bool)
    if ns == false
        execute_data_op(sock, op, args, ro, ns, jl)
    else
        execute_ns_op(sock, op, args, ro, ns, jl)
    end
    close(sock)
    isopen(sock) && @debug("isopen(sock) = true")
end

function execute_data_op(sock, op::Int32, args, ro::Bool, ns::Bool, jl::Bool)
    # Get Attributes
    if op == OP_READ
        (fid::id_t, off::UInt64, size::UInt64) = args
    elseif op == OP_WRITE
        (fid, off, size, buf::Vector{UInt8}) = args
    end
    fattr = ns_worker(OP_GETATTRS, fid, true)
    if isa(fattr, Exception)
        (in_func, out_func) = op_table[op]
        out_func(sock, (fattr, fattr), jl)
        return
    end
    if op == OP_READ && fattr.size < (off + size)
        if fattr.size < off
            (in_func, out_func) = op_table[op]
            out_func(sock, (Vector{UInt8}(), true), jl)
            return
        else
            csize = fattr.size - off
            args = (fid, off, csize)
        end
    end
    # Dispatch to DataWorkers
    ret1 = @pcount("data_worker_call", data_worker(op, args, true))
    # Update Attrs
    ret_attr = update_attrs(op, fattr, off, size)

    # Process and write return value to socket
    (in_func, out_func) = op_table[op]
    out_func(sock, (ret1, ret_attr), jl)
end

function execute_ns_op(sock, op, args, ro, ns, jl)
    @debug("Namespace op: $op, args:$args, ro:$ro")
    ret = ns_worker(op, args, ro)
    if isa(ret, RavanaException)
        @debug("Exception! $(ret.msg)")
    end
    # Process and write return value to socket
    (in_func, out_func) = op_table[op]
    @debug("execute() returns $ret")
    out_func(sock, ret, jl)
end

function update_attrs(op, fattr, off, size)
    if op == OP_WRITE && (off + size) > fattr.size
        fattr.size = off + size
        fattr.mtime = fattr.atime = TimeSpec()
        @debug("update_attrs() setting size= $(fattr.size) mtime=atime= $(fattr.mtime)")
        mask::UInt32 = ATTR_SIZE
        #@set_flag(mask, ATTR_MTIME)
        #@set_flag(mask, ATTR_ATIME)
	mask = mask | ATTR_MTIME
	mask = mask | ATTR_MTIME
        args = (fattr.ino, mask, fattr)
        ret = ns_worker(OP_SETATTRS, args, true)
    else
        # Update atime if the user wants to
        true
    end
end

function get_current_fs()
    current_fs == id_t(0) && throw(RavanaInvalidIdException("fs not set", ENODEV))
    return current_fs
end
