/*
Simple test file to send Ravana requests by hand. A more sophisticated client
will likely do something similar.
*/

#include <stdio.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <stdlib.h>
#include <errno.h>
#include "ravana.h"
#include "ravana_interfaces.h"

void rc_readdir(cid_t cid, fid_t fid);
void rc_rmdir(cid_t cid, fid_t fid, char *name);
void rc_unlink(cid_t cid, fid_t fid, char *name);
void rc_create(cid_t cid, fid_t pfid, char *name, FileAttr *attr);
void rc_mkdir(cid_t cid, fid_t pfid, char *name, FileAttr *attr);
void rc_lookup(cid_t cid, fid_t pfid, char *name, FileAttr *attr);


void usage(char *argv[])
{
    printf("%s <filename> <dirname>\n", argv[0]);
    exit(-1);
}

int main(int argc, char *argv[]) {
    int32_t       error = 0;
    file_name_t   fname;
    fid_t         fid = 0;
    uint64_t      lo = 0x50e7c1cb21e3ea0b;
    uint64_t      hi = 0x9bdc739f3962c66;
    cid_t         cid = UINT128(lo, hi);
    FileAttr      attr = {0};
    FileAttr      attr_out = {0};
    uint64_t      max = -1;
    uint32_t      attr_mask;

    /* validate arguments */
    if(argc != 3)
        usage(argv);

    /* test create */
    rc_create(cid, ROOT, argv[1], &attr_out);

    /* test lookup */
    rc_lookup(cid, ROOT, argv[1], &attr_out);

    /* change size of the file */
    fid = attr_out.ino;
    attr_mask = RFS_ATTR_SIZE;
    attr.size = 4096; /* random test size */
    /* test setattr */
    error = rfs_setattr(cid,
            fid,
            attr_mask,
            attr);
    if(!error) {
        printf("Setattr success.\n\n");
    }
    else {
        printf("Setattr failed, error:%d\n", error);
        exit(error);
    }

    memset(&attr,0, sizeof(FileAttr));
    /* test getattr */
    error = rfs_getattr(cid,
            fid,
            &attr);
    /* get file size */
    if(!error) {
        printf("Getattr success:\n"); 
        printf("FileId %lx%lx \n", (uint64_t)((attr.ino>>64) & max), (uint64_t)(attr.ino & max));
        printf("Size %lx\n\n", (uint64_t)attr.size);
        printf("a_time:%lx m_time:%lx c_time:%lx\n\n", (uint64_t)attr.atime.tv_sec, attr.mtime.tv_sec,attr.ctime.tv_sec); 
    }
    else {
        printf("Failed to getattr, error:%d\n", error);
        exit(error);
    }
    /* readdir test on ROOT */
    rc_readdir(cid, ROOT);
    /* Write test */
    {
        char buffer[256] = "some text to write to file.";
        __int64_t out_size = 0;

        error = rfs_write(cid,
                fid,
                4096,
                strlen(buffer),
                buffer,
                &out_size);
        if(!error) {
            printf("File write success:\n");
            printf("Write request size:%lu, size written:%lu:\n\n", strlen(buffer), out_size);
        }
        else {
            printf("Failed to write to file, error:%d\n", error);
            exit(error);
        }

    }

    /* Read test */
    {
        char buffer[256];
        __int64_t out_size = 0;
        __int64_t read_size = 100;


        printf("Reading.\n");
        error = rfs_read(cid,
                fid,
                4090,
                read_size,
                &out_size,
                buffer);
        if(!error) {
            printf("File read success:\n");
            printf("Read request size:%lu, size read:%lu:\n", read_size, out_size);
            printf("%.*s\n\n", (int)out_size, buffer);
        }
        else {
            printf("Failed to read from file, error:%d\n", error);
            exit(error);
        }

    }
    /* test mkdir */
    rc_mkdir(cid, ROOT, argv[2], &attr_out);
    /* test symlink */
    {
        file_name_t link_name;
        char link_path[256];

        sprintf(link_name.name, "symlink_%s", argv[1]);
        link_name.name_len = strlen(link_name.name);
        strcpy(link_path, argv[1]);
        memset(&attr, 0, sizeof(FileAttr));
        attr_mask = RFS_ATTR_MODE;
        attr.mode = 0766;
        /* test create */
        error = rfs_symlink(cid,
                ROOT,
                attr_mask,
                link_name,
                attr,
                &attr_out,
                link_path);
        /*confirm by checking fid */
        if(!error)
            printf("Sucessful symlink creation\n\n");
        else {
            printf("Failed to create symlink, error:%d\n", error);
            exit(error);
        }
    }
    /* test readlink */
    {
        file_name_t link_name;
        char link_path[256];
        size_t size = 0;
        fid_t link_fid = attr_out.ino;

        /* test readlihnk */
        error = rfs_readlink(cid,
                link_fid,
                &size,
                link_path);
        /*confirm by checking fid */
        if(!error)
            printf("Sucessful readlink, out_size:%lu.\n",size);
        else {
            printf("Failed to read symlinki, error:%d\n", error);
            exit(error);
        }
    }
    /* test link */
    {
        file_name_t link_name;

        sprintf(link_name.name, "link_%s", argv[1]);
        link_name.name_len = strlen(link_name.name);

        /* test create */
        error = rfs_link(cid,
                ROOT,
                fid,
                link_name);

        /*confirm by checking fid */
        if(!error)
            printf("Sucessful link create of FileId %lx%lx \n\n", (uint64_t)((fid>>64) & max), (uint64_t)(fid & max));
        else {
            printf("Failed to create link, error:%d\n", error);
            exit(error);
        }
    }
    /* test rename */
    {
        file_name_t old_name;
        file_name_t new_name;

        strcpy(old_name.name, argv[1]);
        old_name.name_len = strlen(old_name.name);
        sprintf(new_name.name, "renamed_%s", argv[1]);
        new_name.name_len = strlen(new_name.name);

        /* test create */
        error = rfs_rename(cid,
                ROOT,
                ROOT,
                old_name,
                new_name);

        /*confirm by checking fid */
        if(!error)
            printf("Sucessful rename\n\n");
        else {
            printf("Failed to rename, error:%d\n", error);
            exit(error);
        }
    }
    /* readdir */
    rc_readdir(cid, ROOT);
    /* test create */
    rc_create(cid, ROOT, argv[1], &attr_out);
    /* unlink file */
    rc_unlink(cid, ROOT, argv[1]);
    /* rmdir dir */
    rc_rmdir(cid, ROOT, argv[2]);
    /* readdir */
    rc_readdir(cid, ROOT);

    return error;
}


void rc_lookup(cid_t cid, fid_t fid, char *obj_name, FileAttr *attr_out)
{
    int32_t       error = 0;
    file_name_t name = {0};

    strcpy(name.name, obj_name);
    name.name_len = strlen(name.name);
    memset(attr_out, 0, sizeof(FileAttr));

    /* test lookup */
    error = rfs_lookup(cid,
            fid,
            name,
            attr_out);

    /*confirm by checking fid */
    if(!error)
        printf("Lookup successFileId %lx%lx\n\n", (uint64_t)((attr_out->ino>>64) & MAX_UINT64), (uint64_t)(attr_out->ino & MAX_UINT64));
    else {
        printf("Failed to lookup file, error:%d\n", error);
        exit(error);
    }
}

void rc_mkdir(cid_t cid, fid_t fid, char *obj_name, FileAttr *attr_out)
{
    int32_t       error = 0;
    file_name_t name = {0};
    FileAttr      attr = {0};
    uint32_t      attr_mask;

    strcpy(name.name, obj_name);
    name.name_len = strlen(name.name);
    attr_mask = RFS_ATTR_MODE;
    attr.mode = 0766;

    /* test create */
    error = rfs_mkdir(cid,
            ROOT,
            attr_mask,
            name,
            attr,
            attr_out);

    /*confirm by checking fid */
    if(!error)
        printf("Sucessful mkdir, FileId:" FID_STR_FMT "\n",
                (uint64_t)((attr_out->ino>>64) & MAX_UINT64),
                (uint64_t)(attr_out->ino & MAX_UINT64));
    else {
        printf("Failed to create dir, error:%d\n", error);
        exit(error);
    }
}

void rc_create(cid_t cid, fid_t fid, char *obj_name, FileAttr *attr_out)
{
    int32_t       error = 0;
    file_name_t name = {0};
    FileAttr      attr = {0};
    uint32_t      attr_mask;

    strcpy(name.name, obj_name);
    name.name_len = strlen(name.name);
    attr_mask = RFS_ATTR_MODE;
    attr.mode = 0766;

    /* test create */
    error = rfs_create(cid,
            ROOT,
            attr_mask,
            name,
            attr,
            attr_out);

    /*confirm by checking fid */
    if(!error)
        printf("Sucessful create, FileId:" FID_STR_FMT "\n",
                (uint64_t)((attr_out->ino>>64) & MAX_UINT64),
                (uint64_t)(attr_out->ino & MAX_UINT64));
    else {
        printf("Failed to create, error:%d\n", error);
        exit(error);
    }
}

void rc_readdir(cid_t cid, fid_t fid)
{
    int32_t       error = 0;
    uint32_t eof = 0;
    uint32_t n_entries = 0;
    rfs_dirent_t   *entries = NULL;
    error =  rfs_readdir(cid,
            ROOT,
            0,
            &eof,         // true, for end of directory
            &n_entries,   // number of entries returned
            &entries);
    if(!error) {
        uint32_t i = 0;
        printf("Readddir success:\n");
        printf("n_entries:%u\n", n_entries);
        while(i<n_entries) {
            printf("Name %.*s\n", entries[i].fname.name_len, entries[i].fname.name);
            i++;
        }
        free(entries);
    }
    else {
        printf("Failed to readdir, error:%d\n\n", error);
        exit(error);
    }

    return;
}


void rc_unlink(cid_t cid, fid_t fid, char *name)
{
    int32_t       error = 0;
    file_name_t obj_name;

    sprintf(obj_name.name, "%s", name);
    obj_name.name_len = strlen(obj_name.name);

    /* test create */
    error = rfs_unlink(cid,
            fid,
            obj_name);

    /*confirm by checking fid */
    if(!error)
        printf("Sucessful unlink of name:%s\n", obj_name.name);
    else {
        printf("Failed to unlink, error:%d\n\n", error);
        exit(error);
    }
}

void rc_rmdir(cid_t cid, fid_t fid, char *name)
{
    int32_t       error = 0;
    file_name_t obj_name;

    sprintf(obj_name.name, "%s", name);
    obj_name.name_len = strlen(obj_name.name);

    /* test create */
    error = rfs_rmdir(cid,
            fid,
            obj_name);

    /*confirm by checking fid */
    if(!error)
        printf("Sucessful rmdir of name:%s\n", obj_name.name);
    else {
        printf("Failed to rmdir, error:%d\n\n", error);
        exit(error);
    }
}
