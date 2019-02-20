#include <sys/types.h>
#include <sys/stat.h>
#include <fcntl.h>


#define MOUNT_POINT "/mnt/ravana/"


int open();

int open(const char*pathname, int flags)
{
    int mode = 0;
    fid_t fid = 0;

    if(flags & O_CREAT) {
        va_list arg;
        va_start (arg, flags);
        mode = va_arg (arg, int);
        va_end (arg);
    }

    if(!is_ravana(pathname)) {
        if(mode)
            return __open64(pathname, flags, mode);
        else
            return __open64(pathname, flags);
    }

    fid = lookup_int(pathname);
}

/*
 * File systems will be visible in /mnt/ravana/<cid>/
 */
int is_ravana(const char *path)
{
    if(strlen(path) < strlen(MOUNT_POINT)) return 0;
    if(strncmp(path, MOUNT_POINT, strlen(MOUNT_POINT)) == 0) return 1;
    return 0;
}

fid_t lookup_int(const char *pathname)
{
    char *ptr = pathname + strlen(MOUNT_POINT);
    char *comp = NULL;
    while(comp = path_component(ptr)) {
        rfs_lookup(comp)
    }
}
