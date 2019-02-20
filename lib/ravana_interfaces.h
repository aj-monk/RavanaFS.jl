
#ifndef __RAVANA_INTERFACES_H_
#define __RAVANA_INTERFACES_H_

#include "ravana.h"

int rfs_create(cid_t cid,
        fid_t p_fid,
        uint32_t      attr_mask,
        file_name_t   fname,
        FileAttr      attr_in,
        FileAttr      *attr_out);

int rfs_lookup(cid_t  cid,
        fid_t         dfid,
        file_name_t   fname,
        FileAttr      *attr_out);

int rfs_setattr(cid_t cid,
        fid_t         fid,
        uint32_t      attr_mask,
        FileAttr      attr);

int rfs_getattr(cid_t cid,
        fid_t         fid,
        FileAttr      *attr);

int rfs_readdir(cid_t  cid,
        fid_t          dfid,
        uint64_t       index,
        __int32_t      *eof,         // true, for end of directory
        uint32_t       *n_entries,   // number of entries returned
        rfs_dirent_t   **entries);

int rfs_write(cid_t   cid,
        fid_t           fid,
        uint64_t        offset,
        __int64_t       size,
        char            *buffer,
        __int64_t       *out_size);

int rfs_read(cid_t   cid,
        fid_t           fid,
        uint64_t        offset,
        __int64_t       size,
        __int64_t       *out_size,
        char            *buffer);


int rfs_mkdir(cid_t   cid,
        fid_t         p_fid,
        uint32_t      attr_mask,
        file_name_t   dname,
        FileAttr      attr_in,
        FileAttr      *attr_out);

int rfs_unlink(cid_t  cid,
        fid_t         pfid,
        file_name_t   name);

int rfs_rmdir(cid_t  cid,
        fid_t         pfid,
        file_name_t   name);

int rfs_rename(cid_t  cid,
        fid_t         old_dfid,
        fid_t         new_dfid,
        file_name_t   old_name,
        file_name_t   new_name);

int rfs_symlink(cid_t cid,
        fid_t         dfid,
        uint32_t      attr_mask,
        file_name_t   name,
        FileAttr      attr_in,
        FileAttr      *attr_out,
        char*         link_path);

int rfs_link(cid_t  cid,
        fid_t       d_fid,
        fid_t       fid,
        file_name_t name);

int rfs_readlink(cid_t   cid,
        fid_t           fid,
        __int64_t       *out_size,
        char            *buffer);

int rfs_mknod(cid_t  cid,
        fid_t         p_fid,
        uint32_t      attr_mask,
        file_name_t   name,
        FileAttr      attr_in,
        FileAttr      *attr_out);

#endif /* __RAVANA_INTERFACES_H_ */
