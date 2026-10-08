/* Independent SDK oracle: compile/run with the actual macOS SDK, never as root.
 * SDK declarations, not the Python adapter, determine all emitted values. */
#ifndef __APPLE__
#error "This oracle requires an actual Apple SDK and Darwin runtime"
#endif
#include <sys/types.h>
#include <sys/wait.h>
#include <sys/acl.h>
#include <signal.h>
#include <stddef.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>
#include <dlfcn.h>
#include <stdlib.h>

#define ITEM(label, value) printf("%s=%lld\n", label, (long long)(value))
#define OFFSET(field) ITEM("offset." #field, offsetof(siginfo_t, field))
#define MUST(value) do { if (!(value)) { fprintf(stderr, "refused line %d errno %d\n", __LINE__, errno); return 1; } } while (0)

int main(void) {
    siginfo_t first, second;
    int channels[2], status;
    pid_t child;
    char byte;
    Dl_info provenance;
    ITEM("sizeof.siginfo_t", sizeof(siginfo_t));
    ITEM("alignof.siginfo_t", _Alignof(siginfo_t));
    ITEM("sizeof.id_t", sizeof(id_t));
    ITEM("sizeof.pid_t", sizeof(pid_t));
    ITEM("sizeof.uid_t", sizeof(uid_t));
    ITEM("sizeof.long", sizeof(long));
    ITEM("sizeof.pointer", sizeof(void *));
    OFFSET(si_signo); OFFSET(si_errno); OFFSET(si_code); OFFSET(si_pid);
    OFFSET(si_uid); OFFSET(si_status); OFFSET(si_addr); OFFSET(si_value);
    OFFSET(si_band); OFFSET(__pad);
    ITEM("P_ALL", P_ALL); ITEM("P_PID", P_PID); ITEM("P_PGID", P_PGID);
    ITEM("WEXITED", WEXITED); ITEM("WNOHANG", WNOHANG); ITEM("WNOWAIT", WNOWAIT);
    ITEM("CLD_EXITED", CLD_EXITED); ITEM("CLD_KILLED", CLD_KILLED); ITEM("CLD_DUMPED", CLD_DUMPED);
    ITEM("SIGCHLD", SIGCHLD); ITEM("SIGTERM", SIGTERM); ITEM("SIGKILL", SIGKILL);
    ITEM("ACL_TYPE_EXTENDED", ACL_TYPE_EXTENDED); ITEM("ACL_FIRST_ENTRY", ACL_FIRST_ENTRY);
    MUST(dladdr((void *)waitid, &provenance) != 0 && provenance.dli_fname != NULL);
    printf("waitid.library=%s\n", provenance.dli_fname);
    MUST(pipe(channels) == 0);
    child = fork();
    MUST(child >= 0);
    if (child == 0) {
        close(channels[1]);
        /* Parent death gives EOF and also retires this test child. */
        while (read(channels[0], &byte, 1) < 0 && errno == EINTR) {}
        close(channels[0]);
        _exit(7);
    }
    close(channels[0]);
    memset(&first, 0, sizeof(first));
    MUST(waitid(P_PID, (id_t)child, &first, WEXITED | WNOHANG | WNOWAIT) == 0);
    MUST(first.si_pid == 0);
    MUST(write(channels[1], "R", 1) == 1);
    close(channels[1]);
    memset(&first, 0, sizeof(first));
    MUST(waitid(P_PID, (id_t)child, &first, WEXITED | WNOWAIT) == 0);
    MUST(first.si_pid == child && first.si_signo == SIGCHLD && first.si_code == CLD_EXITED && first.si_status == 7);
    memset(&second, 0, sizeof(second));
    MUST(waitid(P_PID, (id_t)child, &second, WEXITED | WNOHANG | WNOWAIT) == 0);
    MUST(second.si_pid == first.si_pid && second.si_code == first.si_code && second.si_status == first.si_status && second.si_uid == first.si_uid && second.si_signo == first.si_signo);
    MUST(waitpid(child, &status, 0) == child && WIFEXITED(status) && WEXITSTATUS(status) == 7);
    memset(&second, 0, sizeof(second)); errno = 0;
    MUST(waitid(P_PID, (id_t)child, &second, WEXITED | WNOHANG | WNOWAIT) == -1 && errno == ECHILD);
    puts("native.direct_child_wnowait_reap=PASS");
    acl_t empty = acl_init(0);
    acl_entry_t entry = NULL;
    MUST(empty != NULL && acl_valid(empty) == 0);
    errno = 0;
    int result = acl_get_entry(empty, ACL_FIRST_ENTRY, &entry);
    ITEM("empty_acl.first_entry.result", result);
    ITEM("empty_acl.first_entry.errno", errno);
    MUST(result == -1 && errno == EINVAL && entry == NULL);
    MUST(acl_free(empty) == 0);
    puts("native.empty_acl_api=PASS");
    return 0;
}
