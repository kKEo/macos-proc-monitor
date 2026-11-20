#include "CPmonSys.h"
#include <dlfcn.h>

pid_t pmon_responsible_pid(pid_t pid) {
    static pid_t (*fn)(pid_t) = 0;
    static int looked = 0;
    if (!looked) {
        fn = (pid_t (*)(pid_t))dlsym(RTLD_DEFAULT, "responsibility_get_pid_responsible_for_pid");
        looked = 1;
    }
    return fn ? fn(pid) : -1;
}
