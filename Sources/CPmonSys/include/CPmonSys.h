// C declarations that the Swift Darwin module does not expose.
#ifndef CPMONSYS_H
#define CPMONSYS_H

#include <sys/types.h>
#include <libproc.h>
#include <sys/resource.h>
#include <sys/sysctl.h>

/// Private libsystem call used by Activity Monitor to group helper processes under their app.
/// Returns the responsible pid, or a negative value when it cannot be determined.
/// Resolved lazily at run time so a future OS that drops the symbol does not break launch.
pid_t pmon_responsible_pid(pid_t pid);

#endif
