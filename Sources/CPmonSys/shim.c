#include "CPmonSys.h"
#include <dlfcn.h>
#include <string.h>

pid_t pmon_responsible_pid(pid_t pid) {
    static pid_t (*fn)(pid_t) = 0;
    static int looked = 0;
    if (!looked) {
        fn = (pid_t (*)(pid_t))dlsym(RTLD_DEFAULT, "responsibility_get_pid_responsible_for_pid");
        looked = 1;
    }
    return fn ? fn(pid) : -1;
}

int pmon_proc_basic(pid_t pid, pmon_basic_t *out) {
    struct kinfo_proc kp;
    size_t len = sizeof(kp);
    int mib[4] = {CTL_KERN, KERN_PROC, KERN_PROC_PID, pid};
    if (sysctl(mib, 4, &kp, &len, NULL, 0) != 0 || len < sizeof(kp)) return -1;
    out->ppid = kp.kp_eproc.e_ppid;
    out->uid = kp.kp_eproc.e_ucred.cr_uid;
    out->start_sec = kp.kp_proc.p_starttime.tv_sec;
    out->start_usec = kp.kp_proc.p_starttime.tv_usec;
    out->flags = (uint32_t)kp.kp_proc.p_flag;
    strlcpy(out->comm, kp.kp_proc.p_comm, sizeof(out->comm));
    return 0;
}

// Layouts of two proc_pidinfo flavors that are stable kernel ABI but not in the public headers.
#define PMON_PROC_PIDUNIQIDENTIFIERINFO 17
#define PMON_PROC_PIDCOALITIONINFO 20

struct pmon_uniqidentifierinfo {
    uint8_t  p_uuid[16];
    uint64_t p_uniqueid;
    uint64_t p_puniqueid;
    int32_t  p_idversion;
    int32_t  p_orig_ppidversion;
    uint64_t p_reserve2;
    uint64_t p_reserve3;
};

struct pmon_coalitioninfo {
    uint64_t coalition_id[2];   // [0] resource coalition, [1] jetsam coalition
    uint64_t reserved1, reserved2, reserved3;
};

int pmon_unique_id(pid_t pid, uint64_t *unique_id, uint64_t *parent_unique_id) {
    struct pmon_uniqidentifierinfo info;
    if (proc_pidinfo(pid, PMON_PROC_PIDUNIQIDENTIFIERINFO, 0, &info, sizeof(info)) != (int)sizeof(info)) return -1;
    *unique_id = info.p_uniqueid;
    *parent_unique_id = info.p_puniqueid;
    return 0;
}

int pmon_coalition_id(pid_t pid, uint64_t *coalition_id) {
    struct pmon_coalitioninfo info;
    if (proc_pidinfo(pid, PMON_PROC_PIDCOALITIONINFO, 0, &info, sizeof(info)) != (int)sizeof(info)) return -1;
    *coalition_id = info.coalition_id[0];
    return 0;
}
