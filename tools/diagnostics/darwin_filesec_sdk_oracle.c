/* Independent native SDK oracle; ordinary caller only, never sudo. */
#ifndef __APPLE__
#error "Actual Apple SDK required"
#endif
#include <sys/types.h>
#include <sys/stat.h>
#include <sys/fcntl.h>
#include <sys/acl.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <errno.h>
#include <dlfcn.h>
#define ITEM(name,value) printf("%s=%lld\n",name,(long long)(value))
#define OFFSET(field) ITEM("offset." #field,offsetof(struct stat,field))
#define MUST(condition) do { if (!(condition)) {fprintf(stderr,"refused line %d errno %d\n",__LINE__,errno); return 1;} } while(0)
int main(void) {
    struct stat before, extended, after;
    filesec_t metadata;
    acl_t acl = NULL;
    acl_entry_t entry = NULL;
    Dl_info provenance;
    char locator[] = "/private/var/tmp/ergopti-filesec-oracle-XXXXXX";
    ITEM("sizeof.stat",sizeof(struct stat)); ITEM("alignof.stat",_Alignof(struct stat));
    ITEM("sizeof.timespec",sizeof(struct timespec)); ITEM("alignof.timespec",_Alignof(struct timespec));
    OFFSET(st_dev); OFFSET(st_mode); OFFSET(st_nlink); OFFSET(st_ino); OFFSET(st_uid);
    OFFSET(st_gid); OFFSET(st_rdev); OFFSET(st_atimespec); OFFSET(st_mtimespec); OFFSET(st_ctimespec);
    OFFSET(st_birthtimespec); OFFSET(st_size); OFFSET(st_blocks); OFFSET(st_blksize); OFFSET(st_flags);
    OFFSET(st_gen); OFFSET(st_lspare); OFFSET(st_qspare);
    ITEM("FILESEC_ACL",FILESEC_ACL); ITEM("ACL_FIRST_ENTRY",ACL_FIRST_ENTRY);
    MUST(dladdr((void *)fstatx_np,&provenance) != 0 && provenance.dli_fname != NULL);
    printf("fstatx_np.library=%s\n",provenance.dli_fname);
    int descriptor = mkstemp(locator);
    MUST(descriptor >= 0);
    MUST(unlink(locator) == 0);
    MUST(fstat(descriptor,&before) == 0);
    metadata = filesec_init(); MUST(metadata != NULL);
    errno = 0; MUST(fstatx_np(descriptor,&extended,metadata) == 0);
    MUST(extended.st_dev == before.st_dev && extended.st_ino == before.st_ino && extended.st_mode == before.st_mode && extended.st_uid == before.st_uid && extended.st_gid == before.st_gid);
    errno = 0; int result = filesec_get_property(metadata,FILESEC_ACL,&acl); int observed_errno = errno;
    ITEM("property.result",result); ITEM("property.errno",observed_errno); ITEM("property.nonnull_acl",acl != NULL);
    if (result == -1) {
        MUST(observed_errno == ENOENT && acl == NULL);
        puts("native.fd_acl=ABSENT_AFTER_SUCCESSFUL_FSTATX");
    } else {
        MUST(result == 0 && acl != NULL && acl_valid(acl) == 0);
        errno = 0; MUST(acl_get_entry(acl,ACL_FIRST_ENTRY,&entry) == -1 && errno == EINVAL && entry == NULL);
        MUST(acl_free(acl) == 0);
        puts("native.fd_acl=VALID_ZERO_ENTRY_ACL");
    }
    MUST(fstat(descriptor,&after) == 0);
    MUST(after.st_dev == before.st_dev && after.st_ino == before.st_ino && after.st_mode == before.st_mode && after.st_uid == before.st_uid && after.st_gid == before.st_gid && after.st_size == before.st_size && after.st_mtimespec.tv_sec == before.st_mtimespec.tv_sec && after.st_mtimespec.tv_nsec == before.st_mtimespec.tv_nsec && after.st_ctimespec.tv_sec == before.st_ctimespec.tv_sec && after.st_ctimespec.tv_nsec == before.st_ctimespec.tv_nsec);
    filesec_free(metadata);
    MUST(close(descriptor) == 0);
    puts("native.filesec_probe=PASS");
    return 0;
}
