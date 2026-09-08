#ifndef C_ARNES_PROCESS_H
#define C_ARNES_PROCESS_H

#include <sys/types.h>

// Returns a POSIX error number; never changes the caller's cwd or signal disposition.
int arnes_spawn(pid_t *pid, const char *executable, char *const argv[],
  char *const environment[], const char *cwd, int input, int output, int error);

// 0: still running, 1: reaped, -1: error (errno is preserved).
int arnes_poll_exit(pid_t pid, int *status, int *signaled);

#endif
