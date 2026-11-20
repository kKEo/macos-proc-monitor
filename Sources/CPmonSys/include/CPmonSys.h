// C declarations that the Swift Darwin module does not expose, and small wrappers around
// kernel structures that are awkward to read from Swift (unions, fixed-size char arrays).
#ifndef CPMONSYS_H
#define CPMONSYS_H

#include <sys/types.h>
#include <stdint.h>
#include <libproc.h>
#include <sys/resource.h>
#include <sys/sysctl.h>

/// Private libsystem call used by Activity Monitor to group helper processes under their app.
/// Returns the responsible pid, or a negative value when it cannot be determined.
/// Resolved lazily at run time so a future OS that drops the symbol does not break launch.
pid_t pmon_responsible_pid(pid_t pid);

/// Basic facts about a process. Readable without privileges for every process on the system.
typedef struct {
    int32_t ppid;
    uint32_t uid;
    int64_t start_sec;
    int32_t start_usec;
    uint32_t flags;      // p_flag; see PMON_P_TRANSLATED
    char comm[32];       // short command name, NUL-terminated
} pmon_basic_t;

/// Set in pmon_basic_t.flags when the process runs under Rosetta translation.
#define PMON_P_TRANSLATED 0x00020000u

/// Fill `out` from the kernel process table. Returns 0 on success, -1 if the pid does not exist.
int pmon_proc_basic(pid_t pid, pmon_basic_t *out);

/// Kernel-unique id of the process and of its parent. Never reused within a boot, unlike a pid.
/// Works for every process without privileges. Returns 0 on success.
int pmon_unique_id(pid_t pid, uint64_t *unique_id, uint64_t *parent_unique_id);

/// Resource coalition id (launchd's grouping of an app with its helpers). Returns 0 on success.
int pmon_coalition_id(pid_t pid, uint64_t *coalition_id);

#endif
