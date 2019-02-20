#ifndef __RAVANA_H_
#define __RAVANA_H_

#include <msgpack.h>

#define ROOT (1) /* Thimble block where entire namespace is kept
                  * Also the ROOT directory's inode.
                  */

#define BASE_DIR    "/opt/kinant/"
#define DSOCK       "/RavanaSocket"

// Max file name size
#ifndef NAME_MAX
#define NAME_MAX 256
#endif

// Conversion between 64 bit and 128 bit integers
#define MAX_UINT64 ((uint64_t)-1)
#define LOWER64(u128) ((__uint64_t) ((u128) & (((__uint128_t)1 << 64) - 1)))
#define UPPER64(u128) ((__uint64_t) ((u128) >> 64))
#define UINT128(lo, up) ((__uint128_t)(up) << 64 | (lo))

#define U128_STR_FMT        "%lx%016lx"
#define FID_STR_FMT        U128_STR_FMT
#define CID_STR_FMT        U128_STR_FMT
#define U128_PRINT_STR(u128)    UPPER64(u128), LOWER64(u128)
#define CID_PRINT_STR     U128_PRINT_STR
#define FID_PRINT_STR     U128_PRINT_STR

#define DEFAULT_CID (123)

// FS ops
typedef enum rfs_file_op {OP_LOOKUP      = 1,
                          OP_READDIR     = 2,
                          OP_CREATE      = 3,
                          OP_MKDIR       = 4,
                          OP_SYMLINK     = 5,
                          OP_READLINK    = 6,
                          OP_TEST_ACCESS = 7,
                          OP_GETATTRS    = 8,
                          OP_SETATTRS    = 9,
                          OP_LINK        = 10,
                          OP_RENAME      = 11,
                          OP_UNLINK      = 12,
                          OP_OPEN        = 13,
                          OP_REOPEN      = 14,
                          OP_STATUS      = 15,
                          OP_READ        = 16,
                          OP_WRITE       = 17,
                          OP_COMMIT      = 18,
                          OP_LOCK        = 19,
                          OP_CLOSE       = 20,
                          OP_RMDIR       = 21,
                          OP_MKNOD       = 22
} rfs_file_op_t;

enum rfs_ctrl_op {OP_STOP_SERVER = 1001,
                  OP_UTIL_MKFS   = 1002,
                  OP_GET_SUPER   = 1003,
                  OP_PUT_SUPER   = 1004,
                  OP_MOUNT       = 1005};

/*
#define S_IFMT     (0170000)   //bit mask for the file type bit field
#define S_IFSOCK   (0140000)   //socket
#define S_IFLNK    (0120000)   //symbolic link
#define S_IFREG    (0100000)   //regular file
#define S_IFBLK    (0060000)   //block device
#define S_IFDIR    (0040000)   //directory
#define S_IFCHR    (0020000)   //character device
#define S_IFIFO    (0010000)   //FIFO
*/

typedef __uint128_t cid_t;   // Channel id type
typedef __uint128_t fid_t;  // File id type, or inode num

#define RFS_PROTO_VERSION  (1)
#define RFS_FSAL_CLIENT    (1)
typedef struct rfs_header {
    __uint32_t size;        // Size
    __uint16_t version;     // Proto version
    __uint16_t flags;       // Proto flags
} rfs_header_t;

typedef struct rfs_request {
    rfs_header_t header;
    char         payload[];
} rfs_request_t;

typedef struct rfs_response{
    __uint32_t size;        // Size of response
    void       *payload;    // Returned stuff
} rfs_response_t;

/*
 * ATTR_MASK
 * Used to set stat attributes after create and set attr
 */
#define RFS_ATTR_MODE   (1 << 0)
#define RFS_ATTR_UID    (1 << 1)
#define RFS_ATTR_GID    (1 << 2)
#define RFS_ATTR_SIZE   (1 << 3)
#define RFS_ATTR_ATIME  (1 << 4)
#define RFS_ATTR_MTIME  (1 << 5)
#define RFS_ATTR_CTIME  (1 << 6)

#define FILE_VERSION (1)
typedef struct file_attr {
    __uint32_t mode;        // File mode
    __uint32_t uid;         // Uid of owner
    __uint32_t gid;         // Group id
    __uint32_t links;       // Number of links
    __uint64_t size;        // for directories = num entries in it
    cid_t       dev;        // cid
    fid_t       ino;        // inode num
    __uint32_t  rdev;       // Device ID (if file is character or block special).
    struct timespec atime;  // Access time
    struct timespec ctime;  // Change time
    struct timespec mtime;  // Modification time
} FileAttr;

typedef struct ravana_super {
    __int64_t version;         // FS version
    cid_t cid;                 // Backing channel id
    cid_t sid;                 // Last committed stream
    struct timespec create_ts; // Create time stamp
    struct timespec mount_ts;  // Last mount time stamp
} RavanaSuper;

typedef struct file_name {
    short       name_len;        // Length of file name
    char        name[NAME_MAX+1];  // filename
} file_name_t;


// OP_CREATE args. The entire structure is passed to the server.
typedef struct rfs_arg_create {
    rfs_file_op_t op;         // operation code
    cid_t         cid;        // channel id
    fid_t         p_fid;      // parent file id
    uint32_t      attr_mask;  // attr mask to set
    file_name_t   fname;      // File name
    FileAttr      attr;       // Attributes to set
} rfs_arg_create_t;

// OP_CREATE response
// If rfs_response_t returns a size <= sizeof(int32_t) it
// means that only an error is returned and not the other
// parts of this structure.
typedef struct rfs_rsp_create {
    __int32_t     error;      // POSIX error number
    FileAttr      attr;       // Attributes of the created file
} rfs_rsp_create_t;

// OP_LOOKUP
typedef struct rfs_arg_lookup {
    rfs_file_op_t op;        // operation code
    cid_t         cid;       // channel id
    fid_t         dfid;      // Parent dir's fid
    file_name_t   fname;     // File name
} rfs_arg_lookup_t;

// OP_LOOKUP response
// If rfs_response_t returns a size <= sizeof(int32_t) it
// means that only an error is returned and not the other
// parts of this structure.
typedef struct rfs_rsp_lookup {
    __int32_t     error;      // POSIX error
    FileAttr      attr;       // Attributes of the created file
} rfs_rsp_lookup_t;

// OP_SETATTRS
typedef struct rfs_arg_setattr {
    rfs_file_op_t  op;         // operation code
    cid_t          cid;        // channel id
    fid_t          fid;        // file id
    uint32_t       attr_mask;  // attr mask to set
    FileAttr       attr;       // attrs to set
} rfs_arg_setattr_t;

// OP_SETATTRS response
typedef struct rfs_rsp_setattr {
    __int32_t       error;        // POSIX error
} rfs_rsp_setattr_t;

// OP_GETATTRS
typedef struct rfs_arg_getattr {
    rfs_file_op_t   op;        // operation code
    cid_t           cid;       // channel id
    fid_t           fid;       // file id
} rfs_arg_getattr_t;

// OP_GETATTRS response
// If rfs_response_t returns a size <= sizeof(int32_t) it
// means that only an error is returned and not the other
// parts of this structure.
typedef struct rfs_rsp_getattr {
    __int32_t   error;        // POSIX error
    FileAttr    attr;         // get attr resp
} rfs_rsp_getattr_t;

typedef struct rfs_dirent {
    file_name_t fname;        // File Name
    fid_t       fid;          // fid
    uint64_t    whence;       // whence token
    //FileAttr    attr;         // stat for the entry
} rfs_dirent_t;

// OP_READDIR
typedef struct rfs_arg_readdir {
    rfs_file_op_t  op;        // operation code
    cid_t          cid;       // channel id
    fid_t          d_fid;     // directory file id
    uint64_t       index;     // index to start from
} rfs_arg_readdir_t;

// OP_READDIR response
// If rfs_response_t returns a size <= sizeof(int32_t) it
// means that only an error is returned and not the other
// parts of this structure.
typedef struct rfs_rsp_readdir {
    __int32_t    error;       // POSIX error
    __int32_t    eof;         // true, for end of directory
    uint64_t     index;       // index to start from
    uint32_t     n_entries;   // number of entries returned
    rfs_dirent_t entries[];   // readdir entries
} rfs_rsp_readdir_t;


/*
 * OP_READ arguments and response structures
 */
typedef struct rfs_arg_read {
    rfs_file_op_t  op;         /* operation code */
    cid_t          cid;        /* channel id */
    fid_t          fid;        /* file id */
    uint64_t       offset;     /* read request offset */
    __int64_t      size;       /* read request size */
} rfs_arg_read_t;

typedef struct rfs_rsp_read {
    __int32_t   error;      /* POSIX error */
    __int64_t   size;       /* read size */
    char        buffer[];    /* read resp buffer */
} rfs_rsp_read_t;


/*
 * OP_WRITE arguments and response structures
 */
typedef struct rfs_arg_write {
    rfs_file_op_t   op;         /* operation code */
    cid_t           cid;        /* channel id */
    fid_t           fid;        /* file id */
    uint64_t        offset;     /* write request offset */
    __int64_t       size;       /* write request size */
    char            buffer[];   /* data buffer */
} rfs_arg_write_t;

typedef struct rfs_rsp_write {
    __int32_t       error;      /* POSIX error */
    __int64_t       size;       /* written size */
} rfs_rsp_write_t;

// OP_MKDIR args. The entire structure is passed to the server.
typedef struct rfs_arg_mkdir {
    rfs_file_op_t op;         // operation code
    cid_t         cid;        // channel id
    fid_t         p_fid;      // parent dir id
    uint32_t      attr_mask;  // attr mask to set
    file_name_t   dname;      // Dir name
    FileAttr      attr;       // attrs to set
} rfs_arg_mkdir_t;

// OP_MKDIR response
// If rfs_response_t returns a size <= sizeof(int32_t) it
// means that only an error is returned and not the other
// parts of this structure.
typedef struct rfs_rsp_mkdir {
    __int32_t     error;      // POSIX error
    FileAttr      attr;       // Attrs of newly created dir
} rfs_rsp_mkdir_t;

// OP_SYMLINK args. The entire structure is passed to the server.
typedef struct rfs_arg_symlink {
    rfs_file_op_t op;         // operation code
    cid_t         cid;        // channel id
    fid_t         p_fid;      // parent dir id
    uint32_t      attr_mask;  // attr mask to set
    file_name_t   name;       // Link name
    FileAttr      attr;       // attrs to set
    file_name_t	  link_path;  // path to link to
} rfs_arg_symlink_t;

// OP_SYMLINK response
// If rfs_response_t returns a size <= sizeof(int32_t) it
// means that only an error is returned and not the other
// parts of this structure.
typedef struct rfs_rsp_symlink {
    __int32_t     error;      // POSIX error
    FileAttr      attr;       // Attrs of the link created
} rfs_rsp_symlink_t;

// OP_LINK args. The entire structure is passed to the server.
typedef struct rfs_arg_link {
    rfs_file_op_t op;         // operation code
    cid_t         cid;        // channel id
    fid_t         p_fid;      // parent dir id
    fid_t         fid;        // file id to link to
    file_name_t   name;       // Link name
} rfs_arg_link_t;

// OP_LINK response
typedef struct rfs_rsp_link {
    __int32_t     error;      // POSIX error
} rfs_rsp_link_t;

// OP_UNLINK args. The entire structure is passed to the server.
typedef struct rfs_arg_unlink {
    rfs_file_op_t op;         // operation code
    cid_t         cid;        // channel id
    fid_t         p_fid;      // parent file id
    file_name_t   name;       // file name
} rfs_arg_unlink_t;

// OP_UNLINK response
typedef struct rfs_rsp_unlink {
    __int32_t     error;      // POSIX error
} rfs_rsp_unlink_t;

typedef rfs_arg_unlink_t rfs_arg_rmdir_t;
typedef rfs_rsp_unlink_t rfs_rsp_rmdir_t;

// OP_RENAME args. The entire structure is passed to the server.
typedef struct rfs_arg_rename {
    rfs_file_op_t op;         // operation code
    cid_t         cid;        // channel id
    fid_t         old_dfid;   // parent file id
    file_name_t   old_name;   // Link name
    fid_t         new_dfid;   // parent file id
    file_name_t   new_name;   // Link name
} rfs_arg_rename_t;

// OP_RENAME response
typedef struct rfs_rsp_rename {
    __int32_t     error;      // POSIX error
} rfs_rsp_rename_t;

// OP_READLINK args. The entire structure is passed to the server.
typedef struct rfs_arg_readlink {
    rfs_file_op_t op;         // operation code
    cid_t         cid;        // channel id
    fid_t         fid;        // link file id
} rfs_arg_readlink_t;

// OP_RENAME response
typedef struct rfs_rsp_readlink {
    __int32_t   error;     // POSIX error
    __int64_t   size;        /* buffer size */
    char        buffer[];    /* resp buffer */
}rfs_rsp_readlink_t;

// OP_MKNOD args. The entire structure is passed to the server.
typedef rfs_arg_create_t rfs_arg_mknod_t;

// OP_MKNOD response
typedef struct rfs_rsp_mknod {
    __int32_t     error;      // POSIX error
    FileAttr      attr;       // Attrs of newly created device
} rfs_rsp_mknod_t;


// OP_STATFS args. The entire structure is passed to the server.
typedef struct rfs_arg_statfs {
    rfs_file_op_t op;         // operation code
    cid_t         cid;        // channel id
} rfs_arg_statfs_t;

// OP_STATFS response
typedef struct rfs_rsp_statfs {
    uint64_t bsize;     /* Filesystem block size */
    uint64_t frsize;    /* Fragemnt size */
    uint64_t blocks;    /* Size of fs in f_frsize units */
    uint64_t bfree;     /* Number of free blocks */
    uint64_t bavail;    /* Number of free blocks for
                           underprivileged user */
    uint64_t files;     /* Number of inodes */
    uint64_t ffree;     /* Number of free inodes */
    uint64_t favail;    /* Number of free inodes for
                           underprivileged user */
    cid_t    cid;       /* channel-id */
    uint64_t flags;     /* Mount flags */
    uint64_t namemax;   /* Max filename length */
}rfs_rsp_statfs_t;

// Function declarations
rfs_request_t * serialize_request(void *opaque_ptr);
int deserialize_rsp_create(const char *packed_buf, int size, rfs_rsp_create_t *response);
int deserialize_rsp_lookup(const char *packed_buf, int size, rfs_rsp_lookup_t *response);
int deserialize_rsp_setattr(const char *packed_buf, int size, rfs_rsp_setattr_t *response);
int deserialize_rsp_getattr(const char *packed_buf, int size, rfs_rsp_getattr_t *response);
int deserialize_rsp_readdir(const char *packed_buf, int size, rfs_rsp_readdir_t *response);
int deserialize_rsp_readdir_entries(const char *packed_buf, int size, rfs_rsp_readdir_t *response); 
int deserialize_rsp_write(const char *packed_buf, int size, rfs_rsp_write_t *response);
int deserialize_rsp_read(const char *packed_buf, int size, rfs_rsp_read_t *response);
int deserialize_rsp_readlink(const char *packed_buf, int size, rfs_rsp_readlink_t *response);
int deserialize_rsp_rename(const char *packed_buf, int size, rfs_rsp_rename_t *response);
int deserialize_rsp_unlink(const char *packed_buf, int size, rfs_rsp_unlink_t *response);
int deserialize_rsp_rmdir(const char *packed_buf, int size, rfs_rsp_rmdir_t *response);
int deserialize_rsp_link(const char *packed_buf, int size, rfs_rsp_link_t *response);
int deserialize_rsp_symlink(const char *packed_buf, int size, rfs_rsp_symlink_t *response);
int deserialize_rsp_mkdir(const char *packed_buf, int size, rfs_rsp_mkdir_t *response);
int deserialize_rsp_mknod(const char *packed_buf, int size, rfs_rsp_mknod_t *response); 
#endif //  __RAVANA_H
