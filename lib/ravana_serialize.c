/* See msgpack documentation at:
 * https://github.com/msgpack/msgpack-c/wiki/v2_0_c_overview
 * To install msgpack see:
 * https://github.com/msgpack/msgpack-c
 */

#include <errno.h>
#include <sys/types.h>
#include <msgpack.h>
#include <unistd.h>
#include "ravana.h"

#define UNPACKER_INIT()							\
    int ret = 0;							\
    msgpack_unpacker pac;						\
    msgpack_unpacked result;						\
    msgpack_unpacker_init(&pac, MSGPACK_UNPACKER_INIT_BUFFER_SIZE);	\
    msgpack_unpacker_reserve_buffer(&pac, size);			\
    memcpy(msgpack_unpacker_buffer(&pac), packed_buf, size);		\
    msgpack_unpacker_buffer_consumed(&pac, size);			\
    msgpack_unpacked_init(&result);

#define UNPACKER_FREE_AND_RETURN()	\
    msgpack_unpacked_destroy(&result);	\
    msgpack_unpacker_destroy(&pac);	\
    return ret;				

#define UNPACK_ERRNO_AND_ATTR()						\
    unpack_generic_int32(&pac, &result, &response->error);		\
    unpack_generic_uint32(&pac, &result, &response->attr.mode);		\
    unpack_generic_uint32(&pac, &result, &response->attr.uid);		\
    unpack_generic_uint32(&pac, &result, &response->attr.gid);		\
    unpack_generic_uint32(&pac, &result, &response->attr.links);	\
    unpack_generic_uint64(&pac, &result, &response->attr.size);		\
    unpack_generic_uint128(&pac, &result, &response->attr.dev);		\
    unpack_generic_uint128(&pac, &result, &response->attr.ino);		\
    unpack_generic_uint32(&pac, &result, &response->attr.rdev);		\
    unpack_generic_uint64(&pac, &result, &response->attr.atime.tv_sec);	\
    unpack_generic_uint64(&pac, &result, &response->attr.atime.tv_nsec);	\
    unpack_generic_uint64(&pac, &result, &response->attr.ctime.tv_sec);	\
    unpack_generic_uint64(&pac, &result, &response->attr.ctime.tv_nsec);	\
    unpack_generic_uint64(&pac, &result, &response->attr.mtime.tv_sec);	\
    unpack_generic_uint64(&pac, &result, &response->attr.mtime.tv_nsec);	\

// Serialize file_name_t structure
static inline int serialize_fname(msgpack_packer *pk, file_name_t *fname) {
    msgpack_pack_bin(pk, fname->name_len);
    msgpack_pack_bin_body(pk, fname->name, fname->name_len);
    return 0;
}

// Serialize timespec structure
static inline int serialize_timespec(msgpack_packer *pk, struct timespec *ts) {
    msgpack_pack_uint64(pk, ts->tv_sec);
    msgpack_pack_uint64(pk, ts->tv_nsec);
    return 0;
}

// Serialize FileAttr structure
static inline int serialize_attr(msgpack_packer *pk, FileAttr *attr) {
    msgpack_pack_uint32(pk, attr->mode);
    msgpack_pack_uint32(pk, attr->uid);
    msgpack_pack_uint32(pk, attr->gid);
    msgpack_pack_uint32(pk, attr->links);
    msgpack_pack_uint64(pk, attr->size);
    msgpack_pack_uint64(pk, LOWER64(attr->dev));
    msgpack_pack_uint64(pk, UPPER64(attr->dev));
    msgpack_pack_uint64(pk, LOWER64(attr->ino));
    msgpack_pack_uint64(pk, UPPER64(attr->ino));
    msgpack_pack_uint32(pk, attr->rdev);
    serialize_timespec(pk, &attr->atime);
    serialize_timespec(pk, &attr->ctime);
    serialize_timespec(pk, &attr->mtime);
    return 0;
}



// Pack an rfs_create argument
static inline void msgpack_pack_create(msgpack_packer *pk, rfs_arg_create_t *cr) {
    msgpack_pack_uint32(pk, cr->op);
    msgpack_pack_uint64(pk, LOWER64(cr->cid));
    msgpack_pack_uint64(pk, UPPER64(cr->cid));
    msgpack_pack_uint64(pk, LOWER64(cr->p_fid));
    msgpack_pack_uint64(pk, UPPER64(cr->p_fid));
    msgpack_pack_uint32(pk, cr->attr_mask);
    serialize_fname(pk, &cr->fname);
    serialize_attr(pk, &cr->attr);
}

// Pack an rfs_symlink argument
static inline void msgpack_pack_symlink(msgpack_packer *pk, rfs_arg_symlink_t *sym) {
    msgpack_pack_uint32(pk, sym->op);
    msgpack_pack_uint64(pk, LOWER64(sym->cid));
    msgpack_pack_uint64(pk, UPPER64(sym->cid));
    msgpack_pack_uint64(pk, LOWER64(sym->p_fid));
    msgpack_pack_uint64(pk, UPPER64(sym->p_fid));
    msgpack_pack_uint32(pk, sym->attr_mask);
    serialize_fname(pk, &sym->name);
    serialize_attr(pk, &sym->attr);
    serialize_fname(pk, &sym->link_path); 
}

// Pack an rfs_rename argument
static inline void msgpack_pack_rename(msgpack_packer *pk, rfs_arg_rename_t *rn) {
    msgpack_pack_uint32(pk, rn->op);
    msgpack_pack_uint64(pk, LOWER64(rn->cid));
    msgpack_pack_uint64(pk, UPPER64(rn->cid));
    msgpack_pack_uint64(pk, LOWER64(rn->old_dfid));
    msgpack_pack_uint64(pk, UPPER64(rn->old_dfid));
    serialize_fname(pk, &rn->old_name);
    msgpack_pack_uint64(pk, LOWER64(rn->new_dfid));
    msgpack_pack_uint64(pk, UPPER64(rn->new_dfid));
    serialize_fname(pk, &rn->new_name);
}

// Pack an rfs_link argument
static inline void msgpack_pack_link(msgpack_packer *pk, rfs_arg_link_t *l) {
    msgpack_pack_uint32(pk, l->op);
    msgpack_pack_uint64(pk, LOWER64(l->cid));
    msgpack_pack_uint64(pk, UPPER64(l->cid));
    msgpack_pack_uint64(pk, LOWER64(l->p_fid));
    msgpack_pack_uint64(pk, UPPER64(l->p_fid));
    msgpack_pack_uint64(pk, LOWER64(l->fid));
    msgpack_pack_uint64(pk, UPPER64(l->fid));
    serialize_fname(pk, &l->name);
}

// Pack an rfs_unlink argument
static inline void msgpack_pack_unlink(msgpack_packer *pk, rfs_arg_unlink_t *ul) {
    msgpack_pack_uint32(pk, ul->op);
    msgpack_pack_uint64(pk, LOWER64(ul->cid));
    msgpack_pack_uint64(pk, UPPER64(ul->cid));
    msgpack_pack_uint64(pk, LOWER64(ul->p_fid));
    msgpack_pack_uint64(pk, UPPER64(ul->p_fid));
    serialize_fname(pk, &ul->name);
}

// Pack an rfs_lookup argument
static inline void msgpack_pack_lookup(msgpack_packer *pk, rfs_arg_lookup_t *lr) {
    msgpack_pack_uint32(pk, lr->op);
    msgpack_pack_uint64(pk, LOWER64(lr->cid));
    msgpack_pack_uint64(pk, UPPER64(lr->cid));
    msgpack_pack_uint64(pk, LOWER64(lr->dfid));
    msgpack_pack_uint64(pk, UPPER64(lr->dfid));
    serialize_fname(pk, &lr->fname);
}

// Pack an rfs_setattr argument
static inline void msgpack_pack_setattr(msgpack_packer *pk, rfs_arg_setattr_t *sr) {
    msgpack_pack_uint32(pk, sr->op);
    msgpack_pack_uint64(pk, LOWER64(sr->cid));
    msgpack_pack_uint64(pk, UPPER64(sr->cid));
    msgpack_pack_uint64(pk, LOWER64(sr->fid));
    msgpack_pack_uint64(pk, UPPER64(sr->fid));
    msgpack_pack_uint32(pk, sr->attr_mask);
    serialize_attr(pk, &sr->attr);
}

// Pack an rfs_getattr argument
static inline void msgpack_pack_getattr(msgpack_packer *pk, rfs_arg_getattr_t *gr) {
    msgpack_pack_uint32(pk, gr->op);
    msgpack_pack_uint64(pk, LOWER64(gr->cid));
    msgpack_pack_uint64(pk, UPPER64(gr->cid));
    msgpack_pack_uint64(pk, LOWER64(gr->fid));
    msgpack_pack_uint64(pk, UPPER64(gr->fid));
}

// Pack an rfs_readdir argument
static inline void msgpack_pack_readdir(msgpack_packer *pk, rfs_arg_readdir_t *rdr) {
    msgpack_pack_uint32(pk, rdr->op);
    msgpack_pack_uint64(pk, LOWER64(rdr->cid));
    msgpack_pack_uint64(pk, UPPER64(rdr->cid));
    msgpack_pack_uint64(pk, LOWER64(rdr->d_fid));
    msgpack_pack_uint64(pk, UPPER64(rdr->d_fid));
    msgpack_pack_uint64(pk, rdr->index);
}

// Pack rfs_read
static inline void msgpack_pack_read(msgpack_packer *pk, rfs_arg_read_t *rd ) {
    msgpack_pack_uint32(pk, rd->op);
    msgpack_pack_uint64(pk, LOWER64(rd->cid));
    msgpack_pack_uint64(pk, UPPER64(rd->cid));
    msgpack_pack_uint64(pk, LOWER64(rd->fid));
    msgpack_pack_uint64(pk, UPPER64(rd->fid));
    msgpack_pack_uint64(pk, rd->offset);
    msgpack_pack_int64(pk, rd->size);
}

// Pack rfs_readlink
static inline void msgpack_pack_readlink(msgpack_packer *pk, rfs_arg_readlink_t *rdl) {
    msgpack_pack_uint32(pk, rdl->op);
    msgpack_pack_uint64(pk, LOWER64(rdl->cid));
    msgpack_pack_uint64(pk, UPPER64(rdl->cid));
    msgpack_pack_uint64(pk, LOWER64(rdl->fid));
    msgpack_pack_uint64(pk, UPPER64(rdl->fid));
}

// Pack rfs_write
static inline void msgpack_pack_write(msgpack_packer *pk, rfs_arg_write_t *wr) {
    msgpack_pack_uint32(pk, wr->op);
    msgpack_pack_uint64(pk, LOWER64(wr->cid));
    msgpack_pack_uint64(pk, UPPER64(wr->cid));
    msgpack_pack_uint64(pk, LOWER64(wr->fid));
    msgpack_pack_uint64(pk, UPPER64(wr->fid));
    msgpack_pack_uint64(pk, wr->offset);
    msgpack_pack_uint64(pk, wr->size);
    // Pack the write buffer
    msgpack_pack_bin(pk, wr->size);
    msgpack_pack_bin_body(pk, wr->buffer, wr->size);
}

// Pack rfs_mkdir
static inline void msgpack_pack_mkdir(msgpack_packer *pk, rfs_arg_mkdir_t *mkd) {
    msgpack_pack_uint32(pk, mkd->op);
    msgpack_pack_uint64(pk, LOWER64(mkd->cid));
    msgpack_pack_uint64(pk, UPPER64(mkd->cid));
    msgpack_pack_uint64(pk, LOWER64(mkd->p_fid));
    msgpack_pack_uint64(pk, UPPER64(mkd->p_fid));
    msgpack_pack_uint32(pk, mkd->attr_mask);
    serialize_fname(pk, &mkd->dname);
    serialize_attr(pk, &mkd->attr);
}

// Pack rfs_rmdir
static inline void msgpack_pack_rmdir(msgpack_packer *pk, rfs_arg_rmdir_t *rmd) {
    msgpack_pack_uint32(pk, rmd->op);
    msgpack_pack_uint64(pk, LOWER64(rmd->cid));
    msgpack_pack_uint64(pk, UPPER64(rmd->cid));
    msgpack_pack_uint64(pk, LOWER64(rmd->p_fid));
    msgpack_pack_uint64(pk, UPPER64(rmd->p_fid));
    serialize_fname(pk, &rmd->name);
}

// Generic call to serialize an incoming request.
// opaque_ptr to a rfs_arg(ravana fs argument)
// opaque_ptr will be type cast to the appropriate type
rfs_request_t * serialize_request(void *opaque_ptr) {
    rfs_request_t *req;

    // Init msgpack related
    msgpack_sbuffer *sbuf = msgpack_sbuffer_new();
    msgpack_packer *pak = msgpack_packer_new(sbuf, msgpack_sbuffer_write);

    // Opaque ptr points to a request arg structure
    // First field in request arg is always an opcode
    // This is why we need multiple dispatch in C
    switch(*(int *)opaque_ptr) {
        case OP_LOOKUP:
            msgpack_pack_lookup(pak, (rfs_arg_lookup_t *)opaque_ptr);
            break;
        case OP_CREATE:
            msgpack_pack_create(pak, (rfs_arg_create_t *)opaque_ptr);
            break;
        case OP_MKNOD:
            msgpack_pack_create(pak, (rfs_arg_create_t *)opaque_ptr);
            break;
        case OP_SETATTRS:
            msgpack_pack_setattr(pak, (rfs_arg_setattr_t *)opaque_ptr);
            break;
        case OP_GETATTRS:
            msgpack_pack_getattr(pak, (rfs_arg_getattr_t *)opaque_ptr);
            break;
        case OP_READDIR:
            msgpack_pack_readdir(pak, (rfs_arg_readdir_t *)opaque_ptr);
            break;
        case OP_READ:
            msgpack_pack_read(pak, (rfs_arg_read_t *)opaque_ptr);
            break;
        case OP_WRITE:
            msgpack_pack_write(pak, (rfs_arg_write_t *)opaque_ptr);
            break;
        case OP_MKDIR:
            msgpack_pack_mkdir(pak, (rfs_arg_mkdir_t *)opaque_ptr);
            break;
        case OP_RMDIR:
            msgpack_pack_rmdir(pak, (rfs_arg_rmdir_t *)opaque_ptr);
            break;
        case OP_SYMLINK:
            msgpack_pack_symlink(pak, (rfs_arg_symlink_t *)opaque_ptr);
            break;
        case OP_LINK:
            msgpack_pack_link(pak, (rfs_arg_link_t *)opaque_ptr);
            break;
        case OP_RENAME:
            msgpack_pack_rename(pak, (rfs_arg_rename_t *)opaque_ptr);
            break;
        case OP_UNLINK:
            msgpack_pack_unlink(pak, (rfs_arg_unlink_t *)opaque_ptr);
            break;
        case OP_READLINK:
            msgpack_pack_readlink(pak, (rfs_arg_readlink_t *)opaque_ptr);
            break;
        case OP_TEST_ACCESS:
        case OP_OPEN:
        case OP_REOPEN:
        case OP_STATUS:
        case OP_COMMIT:
        case OP_LOCK:
        case OP_CLOSE:
        default:
            perror("Operation not Implemented!");
	    msgpack_sbuffer_free(sbuf);
	    msgpack_packer_free(pak);
            return NULL;
    }
    // Create request structure
    if ((req = malloc(sizeof(rfs_request_t) + sbuf->size + 1)) == NULL) {
      perror("request structure error");
      msgpack_sbuffer_free(sbuf);
      msgpack_packer_free(pak);
      return NULL;
    }
    req->header.version = RFS_PROTO_VERSION;
    req->header.flags = RFS_FSAL_CLIENT;
    req->header.size = sbuf->size;
    memcpy(req->payload, sbuf->data, sbuf->size);
    msgpack_sbuffer_free(sbuf);
    msgpack_packer_free(pak);
    return req;
}

static inline int unpacker_init(msgpack_unpacker **pac, msgpack_unpacked **result, int size, const char *packed_buf) {
    int ret = 0;
    /* msgpack_unpacker init */
    if ((*pac = (msgpack_unpacker *)malloc(sizeof(msgpack_unpacker))) == NULL) {
	perror("unpacker_init error");
	return ENOMEM;
    }

    if ((*result = (msgpack_unpacked *)malloc(sizeof(msgpack_unpacked))) == NULL) {
	perror("unpacker_init error");
	return ENOMEM;
    }
    msgpack_unpacker_init(*pac, MSGPACK_UNPACKER_INIT_BUFFER_SIZE);

    /* in-buffer copy and accounting */
    msgpack_unpacker_reserve_buffer(*pac, size);
    memcpy(msgpack_unpacker_buffer(*pac), packed_buf, size);
    msgpack_unpacker_buffer_consumed(*pac, size);

    /* start streaming deserialization. */
    msgpack_unpacked_init(*result);
    return ret;
}

// Note that the following series of functions each call msgpack_unpacker_next()
// and assume that you have allocated and initialised pac and result. They're basically
// fancy macros that the compiler will optimise anyway.
static inline void unpack_generic_int32(msgpack_unpacker *pac, msgpack_unpacked *result, __int32_t *generic) {
    msgpack_unpacker_next(pac, result);
    *generic = (__int32_t)(result->data.via.u64);
}

static inline void unpack_generic_int64(msgpack_unpacker *pac, msgpack_unpacked *result, __int64_t *generic) {
    msgpack_unpacker_next(pac, result);
    *generic = (__int64_t)(result->data.via.u64);
}

static inline void unpack_generic_uint16(msgpack_unpacker *pac, msgpack_unpacked *result, __uint16_t *generic) {
    msgpack_unpacker_next(pac, result);
    *generic = (__uint16_t)result->data.via.u64;
}

static inline void unpack_generic_uint32(msgpack_unpacker *pac, msgpack_unpacked *result, __uint32_t *generic) {
    msgpack_unpacker_next(pac, result);
    *generic = (__uint32_t)result->data.via.u64;
}

static inline void unpack_generic_uint64(msgpack_unpacker *pac, msgpack_unpacked *result, __uint64_t *generic) {
    msgpack_unpacker_next(pac, result);
    *generic = (__uint64_t)result->data.via.u64;
}

static inline void unpack_generic_uint128(msgpack_unpacker *pac, msgpack_unpacked *result, __uint128_t *generic) {
    msgpack_unpacker_next(pac, result);
    __uint64_t flo = result->data.via.u64;
    msgpack_unpacker_next(pac, result);
    __uint64_t fup = result->data.via.u64;
    *generic = UINT128(flo, fup);
}

static inline void unpack_fname(msgpack_unpacker *pac, msgpack_unpacked *result, file_name_t *generic) {
    msgpack_unpacker_next(pac, result);
    memcpy(generic->name, result->data.via.str.ptr, result->data.via.str.size);
    generic->name_len = (short)result->data.via.str.size;
}

static inline void unpack_generic_buffer(msgpack_unpacker *pac, msgpack_unpacked *result, char *generic) {
    msgpack_unpacker_next(pac, result);
    memcpy(generic, result->data.via.str.ptr, result->data.via.str.size);
}
/* Calls for derserializing responses from ravana. In each packed_buf is what's sent in
 * and the response buf is allocated and freed by the caller
 */

/* Create response deserialize */
int deserialize_rsp_create(const char *packed_buf, int size, rfs_rsp_create_t *response) {
    UNPACKER_INIT();
    UNPACK_ERRNO_AND_ATTR();
    UNPACKER_FREE_AND_RETURN();
}

// Deserialize lookup
int deserialize_rsp_lookup(const char *packed_buf, int size, rfs_rsp_lookup_t *response) {
    UNPACKER_INIT();
    UNPACK_ERRNO_AND_ATTR();
    UNPACKER_FREE_AND_RETURN();
}

int deserialize_rsp_setattr(const char *packed_buf, int size, rfs_rsp_setattr_t *response) {
    UNPACKER_INIT();
    unpack_generic_int32(&pac, &result, &response->error);
    UNPACKER_FREE_AND_RETURN();
}

int deserialize_rsp_getattr(const char *packed_buf, int size, rfs_rsp_getattr_t *response) {
    UNPACKER_INIT();
    UNPACK_ERRNO_AND_ATTR();
    UNPACKER_FREE_AND_RETURN();
}

int deserialize_rsp_mkdir(const char *packed_buf, int size, rfs_rsp_mkdir_t *response) {
    UNPACKER_INIT();
    UNPACK_ERRNO_AND_ATTR();
    UNPACKER_FREE_AND_RETURN();
}

int deserialize_rsp_symlink(const char *packed_buf, int size, rfs_rsp_symlink_t *response) {
    UNPACKER_INIT();
    UNPACK_ERRNO_AND_ATTR();
    UNPACKER_FREE_AND_RETURN();
}

int deserialize_rsp_readdir(const char *packed_buf, int size, rfs_rsp_readdir_t *response) {
    UNPACKER_INIT();
    unpack_generic_int32(&pac, &result, &response->error);
    unpack_generic_int32(&pac, &result, &response->eof);
    unpack_generic_uint32(&pac, &result, &response->n_entries);
    UNPACKER_FREE_AND_RETURN();
}

int deserialize_rsp_readdir_entries(const char *packed_buf, int size, rfs_rsp_readdir_t *response) {
    UNPACKER_INIT();
    unpack_generic_int32(&pac, &result, &response->error);
    unpack_generic_int32(&pac, &result, &response->eof);
    unpack_generic_uint32(&pac, &result, &response->n_entries);

    for(int i=0; i<response->n_entries; i++) {
        unpack_fname(&pac, &result, &response->entries[i].fname);
        unpack_generic_uint128(&pac, &result, &response->entries[i].fid);
        unpack_generic_uint64(&pac, &result, &response->entries[i].whence);
    }
    UNPACKER_FREE_AND_RETURN();
}

int deserialize_rsp_read(const char *packed_buf, int size, rfs_rsp_read_t *response) {
    UNPACKER_INIT();
    unpack_generic_int32(&pac, &result, &response->error);
    unpack_generic_int64(&pac, &result, &response->size);
    unpack_generic_buffer(&pac, &result, response->buffer);
    UNPACKER_FREE_AND_RETURN();
}

int deserialize_rsp_readlink(const char *packed_buf, int size, rfs_rsp_readlink_t *response) {
    UNPACKER_INIT();
    unpack_generic_int32(&pac, &result, &response->error);
    unpack_generic_int64(&pac, &result, &response->size);
    unpack_generic_buffer(&pac, &result, response->buffer);
    UNPACKER_FREE_AND_RETURN();
}

int deserialize_rsp_write(const char *packed_buf, int size, rfs_rsp_write_t *response) {
    UNPACKER_INIT();
    unpack_generic_int32(&pac, &result, &response->error);
    unpack_generic_int64(&pac, &result, &response->size);
    UNPACKER_FREE_AND_RETURN();
}

int deserialize_rsp_link(const char *packed_buf, int size, rfs_rsp_link_t *response) {
    UNPACKER_INIT();
    unpack_generic_int32(&pac, &result, &response->error);
    UNPACKER_FREE_AND_RETURN();
}

int deserialize_rsp_unlink(const char *packed_buf, int size, rfs_rsp_unlink_t *response) {
    UNPACKER_INIT();
    unpack_generic_int32(&pac, &result, &response->error);
    UNPACKER_FREE_AND_RETURN();
}

int deserialize_rsp_rmdir(const char *packed_buf, int size, rfs_rsp_rmdir_t *response) {
    UNPACKER_INIT();
    unpack_generic_int32(&pac, &result, &response->error);
    UNPACKER_FREE_AND_RETURN();
}

int deserialize_rsp_rename(const char *packed_buf, int size, rfs_rsp_rename_t *response) {
    UNPACKER_INIT();
    unpack_generic_int32(&pac, &result, &response->error);
    UNPACKER_FREE_AND_RETURN();
}

int deserialize_rsp_mknod(const char *packed_buf, int size, rfs_rsp_mknod_t *response) {
    UNPACKER_INIT();
    UNPACK_ERRNO_AND_ATTR();
    UNPACKER_FREE_AND_RETURN();
}
