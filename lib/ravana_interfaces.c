/*
 * The file contains implimentation of RavanaFS filesystem interfaces
 * defined in ravana_interfaces.h
 */

#include "ravana.h"
#include "ravana_interfaces.h"
#include <stdio.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <stdlib.h>
#include <errno.h>

void get_sock_path(char *path, cid_t cid)
{

    sprintf(path, "/opt/kinant/" CID_STR_FMT "/RavanaSocket",
            CID_PRINT_STR(cid));
#if 0
    sprintf(path, "%s/" CID_STR_FMT "/RavanaSocket" ,
            getenv("KINANT_PATH"), CID_PRINT_STR(cid));
#endif
}
/*
 * Connects, reads and writes to the socket file
 */
int rfs_socket_io(cid_t cid, rfs_request_t *req, rfs_response_t **rsp)
{
    struct sockaddr_un addr = {0};
    int fd;
    uint32_t req_size = 0;
    uint32_t size = 0;
    rfs_response_t *buf = NULL;
    int i=0;
    char sock_path[NAME_MAX+1];


    get_sock_path(sock_path, cid);
    /* Set up socket and structure */
    if ( (fd = socket(AF_UNIX, SOCK_STREAM, 0)) == -1) {
        perror("socket error");
        exit(-1);
    }
    addr.sun_family = AF_UNIX;
    
    strncpy(addr.sun_path, sock_path, sizeof(addr.sun_path)-1);

    /* Connect */
    if (connect(fd, (struct sockaddr*)&addr, sizeof(addr)) == -1) {
        perror("socket connect error");
        exit(-1);
    }

    /* total request size = size of header + payload */
    req_size = sizeof(rfs_request_t) + req->header.size;
    /* Write request to socket */
    if (write(fd, req, req_size) != req_size) {
        perror("write to socket failed: ");
        exit(-1);
    }

    /* First read the size of the response returned */
    if (read(fd, &size, sizeof(uint32_t)) != sizeof(uint32_t)) {
        perror("read failed");
        exit(-1);
    }

    /* Allocate the the payload */
    buf = malloc( size + sizeof(rfs_response_t) );
    if(buf == NULL) {
        perror("malloc failed");
        exit(-1);
    }

    buf->size = size;
    /* payload points to the end of the structure */
    buf->payload = (rfs_response_t *)((char *)buf + sizeof(rfs_response_t));
    /* read the payload */
    if (read(fd, buf->payload, size) != size) {
        perror("read of errno failed");
        exit(-1);
    }
    *rsp = buf;
    shutdown(fd, 2);
    close(fd);


    return 0;
}



/* create */
int rfs_create(cid_t  cid,
        fid_t         p_fid,
        uint32_t      attr_mask,
        file_name_t   fname,
        FileAttr      attr_in,
        FileAttr      *attr_out)
{
    int32_t error = 0;
    rfs_arg_create_t creat;
    rfs_request_t *req = NULL;
    rfs_response_t *rsp = NULL;
    rfs_rsp_create_t creat_rsp = {0};
    void *buf = NULL;

    creat.op = OP_CREATE;
    creat.cid = cid;
    creat.p_fid = p_fid;
    creat.attr_mask = attr_mask;
    creat.attr = attr_in;
    creat.fname = fname;
    // Serialize the request
    if ((req = serialize_request((void *)&creat)) == NULL) {
      perror("serialize request error");
      exit(-1);
    }

    /* Perform socket I/O */
    if(rfs_socket_io(cid, req, &rsp)) {
        perror("socket io failed");
        exit(-1);
    }

    buf = rsp->payload;
    deserialize_rsp_create(buf, rsp->size, &creat_rsp);
    error = creat_rsp.error;
    if(error == 0) {
        if(attr_out)
            memcpy(attr_out, &creat_rsp.attr, sizeof(FileAttr));
    }

    free(req);
    free(rsp);

    return error;
}

/* lookup */
int rfs_lookup(cid_t  cid,
        fid_t         dfid,
        file_name_t   fname,
        FileAttr      *attr_out)
{
    int32_t error = 0;
    rfs_arg_lookup_t lookup;
    rfs_request_t *req = NULL;
    rfs_response_t *rsp = NULL;
    rfs_rsp_lookup_t lookup_rsp = {0};
    void *buf = NULL;

    lookup.op  = OP_LOOKUP;
    lookup.cid = cid;
    lookup.dfid = dfid;
    lookup.fname = fname;
    // Serialize the request
    if ((req = serialize_request((void *)&lookup)) == NULL) {
      perror("serialize request error");
      exit(-1);
    }

    /* Perform socket I/O */
    if(rfs_socket_io(cid, req, &rsp)) {
        perror("socket io failed");
        exit(-1);
    }

    buf = rsp->payload;
    deserialize_rsp_lookup(buf, rsp->size, &lookup_rsp);
    error = lookup_rsp.error;
    if(error == 0) {
        if(attr_out)
            memcpy(attr_out, &lookup_rsp.attr, sizeof(FileAttr));
    }
    free(req);
    free(rsp);

    return error;
}


int rfs_setattr(cid_t cid,
        fid_t         fid,
        uint32_t      attr_mask,
        FileAttr      attr)
{
    int32_t error = 0;
    rfs_arg_setattr_t setattr;
    rfs_request_t *req = NULL;
    rfs_response_t *rsp = NULL;
    rfs_rsp_setattr_t setattr_rsp = {0};
    void *buf = NULL;

    setattr.op  = OP_SETATTRS;
    setattr.cid = cid;
    setattr.fid = fid;
    setattr.attr_mask = attr_mask;
    setattr.attr = attr;
    // Serialize the request
    if ((req = serialize_request((void *)&setattr)) == NULL) {
      perror("serialize request error");
      exit(-1);
    }

    /* Perform socket I/O */
    if(rfs_socket_io(cid, req, &rsp)) {
        perror("socket io failed");
        exit(-1);
    }

    buf = rsp->payload;
    deserialize_rsp_setattr(buf, rsp->size, &setattr_rsp);
    error = setattr_rsp.error; /* assign error */

    free(req);
    free(rsp);

    return error;
}

int rfs_getattr(cid_t cid,
        fid_t         fid,
        FileAttr      *attr)
{
    int32_t error = 0;
    rfs_arg_getattr_t getattr;
    rfs_request_t *req = NULL;
    rfs_response_t *rsp = NULL;
    rfs_rsp_getattr_t getattr_rsp = {0};
    void *buf = NULL;

    getattr.op  = OP_GETATTRS;
    getattr.cid = cid;
    getattr.fid = fid;
    // Serialize the request
    if ((req = serialize_request((void *)&getattr)) == NULL) {
      perror("serialize request error");
      exit(-1);
    }

    /* Perform socket I/O */
    if(rfs_socket_io(cid, req, &rsp)) {
        perror("socket io failed");
        exit(-1);
    }

    buf = rsp->payload;
    deserialize_rsp_getattr(buf, rsp->size, &getattr_rsp);
    error = getattr_rsp.error;
    if(error == 0) {
        if(attr)
            memcpy(attr, &getattr_rsp.attr, sizeof(FileAttr));
    }
    free(req);
    free(rsp);

    return error;
}


int rfs_readdir(cid_t  cid,
        fid_t          dfid,
        uint64_t       index,
        __int32_t      *eof,         // true, for end of directory
        uint32_t       *n_entries,   // number of entries returned
        rfs_dirent_t   **entries)
{
    int32_t error = 0;
    rfs_arg_readdir_t readdir;
    rfs_request_t *req = NULL;
    rfs_response_t *rsp = NULL;
    rfs_rsp_readdir_t readdir_rsp = {0};
    rfs_rsp_readdir_t *readdir_rsp_entries = NULL;
    void *buf = NULL;

    readdir.op  = OP_READDIR;
    readdir.cid = cid;
    readdir.d_fid = dfid;
    readdir.index = index;
    // Serialize the request
    if ((req = serialize_request((void *)&readdir)) == NULL) {
      perror("serialize request error");
      exit(-1);
    }

    /* Perform socket I/O */
    if(rfs_socket_io(cid, req, &rsp)) {
        perror("socket io failed");
        exit(-1);
    }

    buf = rsp->payload;
    deserialize_rsp_readdir(buf, rsp->size, &readdir_rsp);
    error = readdir_rsp.error;
    if(error == 0) {
        /* copy responses back to user args */
        readdir_rsp_entries = malloc(sizeof(rfs_rsp_readdir_t)+
                (size_t)(readdir_rsp.n_entries*sizeof(rfs_dirent_t)));
        if(readdir_rsp_entries == NULL) {
            error = -ENOMEM;
            return error;
        }
        deserialize_rsp_readdir_entries(buf, rsp->size, readdir_rsp_entries);
        if(eof)
            memcpy(eof, &readdir_rsp_entries->eof, sizeof(__int32_t));
        if(n_entries)
            memcpy(n_entries, &readdir_rsp_entries->n_entries, sizeof(uint32_t));

        *entries = malloc((size_t)(*n_entries)*sizeof(rfs_dirent_t));
        if(*entries)
            memcpy(*entries, readdir_rsp_entries->entries, (size_t)(*n_entries)*sizeof(rfs_dirent_t));
        else
            error = -ENOMEM;
    }
    free(req);
    free(rsp);
    free(readdir_rsp_entries);

    return error;
}


int rfs_write(cid_t   cid,
        fid_t           fid,
        uint64_t        offset,
        __int64_t       size,
        char            *buffer,
        __int64_t       *out_size)
{
    int32_t error = 0;
    rfs_arg_write_t *write = NULL;
    rfs_request_t *req = NULL;
    rfs_response_t *rsp = NULL;
    rfs_rsp_write_t write_rsp = {0};
    void *buf = NULL;

    write = malloc(sizeof(rfs_arg_write_t)+size);
    if(write == NULL) {
        perror("Failed to allocate write buffer.\n");
        error = -ENOMEM;
        return error;
    }
    write->op  = OP_WRITE;
    write->cid = cid;
    write->fid = fid;
    write->offset = offset;
    write->size   = size;
    memcpy(write->buffer, buffer, size);
    // Serialize the request
    if ((req = serialize_request((void *)write)) == NULL) {
        perror("serialize request error");
        exit(-1);
    }

    /* Perform socket I/O */
    if(rfs_socket_io(cid, req, &rsp)) {
        perror("socket io failed");
        exit(-1);
    }

    buf = rsp->payload;
    deserialize_rsp_write(buf, rsp->size, &write_rsp);
    error = write_rsp.error; /* assign error */
    if(error == 0) {
        /* copy responses back to user args */
        if(out_size)
            memcpy(out_size, &write_rsp.size, sizeof(__int64_t));
    }
    free(write);
    free(req);
    free(rsp);

    return error;
}


int rfs_read(cid_t   cid,
        fid_t           fid,
        uint64_t        offset,
        __int64_t       size,
        __int64_t       *out_size,
        char            *buffer)
{
    int32_t error = 0;
    rfs_arg_read_t read;
    rfs_request_t *req = NULL;
    rfs_response_t *rsp = NULL;
    rfs_rsp_read_t *read_rsp = NULL;
    void *buf = NULL;

    read_rsp = malloc(sizeof(rfs_rsp_read_t)+ (size_t)size);
    if(read_rsp == NULL) {
        error = -ENOMEM;
        return error;
    }
    read.op  = OP_READ;
    read.cid = cid;
    read.fid = fid;
    read.offset = offset;
    read.size   = size;
    // Serialize the request
    if ((req = serialize_request((void *)&read)) == NULL) {
        perror("serialize request error");
        exit(-1);
    }

    /* Perform socket I/O */
    if(rfs_socket_io(cid, req, &rsp)) {
        perror("socket io failed");
        exit(-1);
    }

    buf = rsp->payload;
    deserialize_rsp_read(buf, rsp->size, read_rsp);
    error = read_rsp->error;
    if(error == 0)
    {
        /* copy responses back to user args */
        if(out_size)
            memcpy(out_size, &read_rsp->size, sizeof(__int64_t));
        if(buffer)
            memcpy(buffer, read_rsp->buffer, (size_t)read_rsp->size);
    }
    free(read_rsp);
    free(req);
    free(rsp);

    return error;
}

int rfs_mkdir(cid_t  cid,
        fid_t         p_fid,
        uint32_t      attr_mask,
        file_name_t   dname,
        FileAttr      attr_in,
        FileAttr      *attr_out)
{
    int32_t error = 0;
    rfs_arg_mkdir_t mkdir;
    rfs_request_t *req = NULL;
    rfs_response_t *rsp = NULL;
    rfs_rsp_mkdir_t mkdir_rsp = {0};
    void *buf = NULL;

    mkdir.op = OP_MKDIR;
    mkdir.cid = cid;
    mkdir.p_fid = p_fid;
    mkdir.attr_mask = attr_mask;
    mkdir.attr = attr_in;
    mkdir.dname = dname;
    // Serialize the request
    if ((req = serialize_request((void *)&mkdir)) == NULL) {
      perror("serialize request error");
      exit(-1);
    }

    /* Perform socket I/O */
    if(rfs_socket_io(cid, req, &rsp)) {
        perror("socket io failed");
        exit(-1);
    }

    buf = rsp->payload;
    deserialize_rsp_mkdir(buf, rsp->size, &mkdir_rsp);
    error = mkdir_rsp.error;
    if(error == 0) {
        /* copy responses back to user args */
        if(attr_out)
            memcpy(attr_out, &mkdir_rsp.attr, sizeof(FileAttr));
    }
    free(req);
    free(rsp);

    return error;
}

int rfs_symlink(cid_t cid,
        fid_t         p_fid,
        uint32_t      attr_mask,
        file_name_t   name,
        FileAttr      attr_in,
        FileAttr      *attr_out,
        char*         link_path)
{
    int32_t error = 0;
    rfs_arg_symlink_t symlink;
    rfs_request_t *req = NULL;
    rfs_response_t *rsp = NULL;
    rfs_rsp_symlink_t symlink_rsp = {0};
    void *buf = NULL;
    file_name_t link_path_int = {0};

    symlink.op = OP_SYMLINK;
    symlink.cid = cid;
    symlink.p_fid = p_fid;
    symlink.attr_mask = attr_mask;
    symlink.attr = attr_in;
    symlink.name = name;
   
    link_path_int.name_len = strlen(link_path);
    if(link_path_int.name_len > NAME_MAX) {
        link_path_int.name_len = NAME_MAX-1;
    }
    strncpy(link_path_int.name, link_path, NAME_MAX-1);
    link_path_int.name[NAME_MAX-1] = '\0';
    symlink.link_path = link_path_int;
    // Serialize the request
    if ((req = serialize_request((void *)&symlink)) == NULL) {
      perror("serialize request error");
      exit(-1);
    }

    /* Perform socket I/O */
    if(rfs_socket_io(cid, req, &rsp)) {
        perror("socket io failed");
        exit(-1);
    }

    buf = rsp->payload;
    deserialize_rsp_symlink(buf, rsp->size, &symlink_rsp);
    error = symlink_rsp.error;
    if(error == 0) {
        /* copy responses back to user args */
        if(attr_out)
            memcpy(attr_out, &symlink_rsp.attr, sizeof(FileAttr));
    }
    free(req);
    free(rsp);

    return error;
}

int rfs_unlink(cid_t  cid,
        fid_t         p_fid,
        file_name_t   name)
{
    int32_t error = 0;
    rfs_arg_unlink_t unlink;
    rfs_request_t *req = NULL;
    rfs_response_t *rsp = NULL;
    rfs_rsp_unlink_t unlink_rsp = {0};
    void *buf = NULL;

    unlink.op = OP_UNLINK;
    unlink.cid = cid;
    unlink.p_fid = p_fid;
    unlink.name = name;
    // Serialize the request
    if ((req = serialize_request((void *)&unlink)) == NULL) {
      perror("serialize request error");
      exit(-1);
    }

    /* Perform socket I/O */
    if(rfs_socket_io(cid, req, &rsp)) {
        perror("socket io failed");
        exit(-1);
    }

    buf = rsp->payload;
    deserialize_rsp_unlink(buf, rsp->size, &unlink_rsp);
    error = unlink_rsp.error; /* assign error */
    free(req);
    free(rsp);

    return error;
}

int rfs_link(cid_t  cid,
        fid_t         p_fid,
        fid_t         fid,
        file_name_t   name)
{
    int32_t error = 0;
    rfs_arg_link_t link;
    rfs_request_t *req = NULL;
    rfs_response_t *rsp = NULL;
    rfs_rsp_link_t link_rsp = {0};
    void *buf = NULL;

    link.op = OP_LINK;
    link.cid = cid;
    link.p_fid = p_fid;
    link.fid = fid;
    link.name = name;
    // Serialize the request
    if ((req = serialize_request((void *)&link)) == NULL) {
      perror("serialize request error");
      exit(-1);
    }

    /* Perform socket I/O */
    if(rfs_socket_io(cid, req, &rsp)) {
        perror("socket io failed");
        exit(-1);
    }

    buf = rsp->payload;
    deserialize_rsp_link(buf, rsp->size, &link_rsp);
    error = link_rsp.error; /* assign error */
    free(req);
    free(rsp);

    return error;
}

int rfs_rmdir(cid_t  cid,
        fid_t         p_fid,
        file_name_t   name)
{
    int32_t error = 0;
    rfs_arg_rmdir_t rmdir;
    rfs_request_t *req = NULL;
    rfs_response_t *rsp = NULL;
    rfs_rsp_rmdir_t rmdir_rsp = {0};
    void *buf = NULL;

    rmdir.op = OP_RMDIR;
    rmdir.cid = cid;
    rmdir.p_fid = p_fid;
    rmdir.name = name;
    // Serialize the request
    if ((req = serialize_request((void *)&rmdir)) == NULL) {
      perror("serialize request error");
      exit(-1);
    }

    /* Perform socket I/O */
    if(rfs_socket_io(cid, req, &rsp)) {
        perror("socket io failed");
        exit(-1);
    }

    buf = rsp->payload;
    deserialize_rsp_rmdir(buf, rsp->size, &rmdir_rsp);
    error = rmdir_rsp.error; /* assign error */
    free(req);
    free(rsp);

    return error;
}

int rfs_rename(cid_t  cid,
        fid_t         old_dfid,
        fid_t         new_dfid,
        file_name_t   old_name,
        file_name_t   new_name)
{
    int32_t error = 0;
    rfs_arg_rename_t rename;
    rfs_request_t *req = NULL;
    rfs_response_t *rsp = NULL;
    rfs_rsp_rename_t rename_rsp = {0};
    void *buf = NULL;

    rename.op = OP_RENAME;
    rename.cid = cid;
    rename.old_dfid = old_dfid;
    rename.new_dfid = new_dfid;
    rename.old_name = old_name;
    rename.new_name = new_name;
    // Serialize the request
    if ((req = serialize_request((void *)&rename)) == NULL) {
      perror("serialize request error");
      exit(-1);
    }

    /* Perform socket I/O */
    if(rfs_socket_io(cid, req, &rsp)) {
        perror("socket io failed");
        exit(-1);
    }

    buf = rsp->payload;
    deserialize_rsp_rename(buf, rsp->size, &rename_rsp);
    error = rename_rsp.error; /* assign error */
    free(req);
    free(rsp);

    return error;
}

int rfs_readlink(cid_t   cid,
        fid_t           fid,
        __int64_t       *out_size,
        char            *buffer)
{
    int32_t error = 0;
    rfs_arg_readlink_t readlink;
    rfs_request_t *req = NULL;
    rfs_response_t *rsp = NULL;
    rfs_rsp_readlink_t *readlink_rsp = NULL;
    void *buf = NULL;

    readlink_rsp = malloc(sizeof(rfs_rsp_readlink_t)+ (size_t)PATH_MAX);
    if(readlink_rsp == NULL) {
        error = -ENOMEM;
        return error;
    }
    readlink.op  = OP_READLINK;
    readlink.cid = cid;
    readlink.fid = fid;
    // Serialize the request
    if ((req = serialize_request((void *)&readlink)) == NULL) {
        perror("serialize request error");
        exit(-1);
    }

    /* Perform socket I/O */
    if(rfs_socket_io(cid, req, &rsp)) {
        perror("socket io failed");
        exit(-1);
    }

    buf = rsp->payload;
    deserialize_rsp_readlink(buf, rsp->size, readlink_rsp);
    error = readlink_rsp->error;
    if(error == 0) {
        /* copy responses back to user args */
        if(out_size)
            memcpy(out_size, &readlink_rsp->size, sizeof(__int64_t));
        if(buffer)
            memcpy(buffer, readlink_rsp->buffer, (size_t)readlink_rsp->size);
    }
    free(readlink_rsp);
    free(req);
    free(rsp);

    return error;
}


int rfs_mknod(cid_t  cid,
        fid_t         p_fid,
        uint32_t      attr_mask,
        file_name_t   name,
        FileAttr      attr_in,
        FileAttr      *attr_out)
{
    int32_t error = 0;
    rfs_arg_mknod_t mknod;
    rfs_request_t *req = NULL;
    rfs_response_t *rsp = NULL;
    rfs_rsp_mknod_t mknod_rsp = {0};
    void *buf = NULL;

    mknod.op = OP_MKNOD;
    mknod.cid = cid;
    mknod.p_fid = p_fid;
    mknod.attr_mask = attr_mask;
    mknod.attr = attr_in;
    mknod.fname = name;
    // Serialize the request
    if ((req = serialize_request((void *)&mknod)) == NULL) {
      perror("serialize request error");
      exit(-1);
    }

    /* Perform socket I/O */
    if(rfs_socket_io(cid, req, &rsp)) {
        perror("socket io failed");
        exit(-1);
    }

    buf = rsp->payload;
    deserialize_rsp_mknod(buf, rsp->size, &mknod_rsp);
    error = mknod_rsp.error;
    if(error == 0) {
        /* copy responses back to user args */
        if(attr_out)
            memcpy(attr_out, &mknod_rsp.attr, sizeof(FileAttr));
    }
    free(req);
    free(rsp);

    return error;
}
