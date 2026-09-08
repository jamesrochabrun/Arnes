#if defined(__linux__)
#define _GNU_SOURCE
#include "CArnesProcess.h"
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <spawn.h>
#include <sys/wait.h>
#include <unistd.h>

int arnes_spawn(pid_t *pid, const char *executable, char *const argv[],
  char *const environment[], const char *cwd, int input, int output, int error) {
  posix_spawn_file_actions_t actions;
  posix_spawnattr_t attributes;
  int result = posix_spawn_file_actions_init(&actions);
  if (result) return result;
  result = posix_spawnattr_init(&attributes);
  if (result) {
    posix_spawn_file_actions_destroy(&actions);
    return result;
  }

  // Duplicate above stderr first, so redirections also work when the caller has
  // closed one of its standard descriptors. Every temporary is close-on-exec.
  int sources[3] = {input, output, error};
  int copies[3] = {-1, -1, -1};
  for (int i = 0; i < 3; i++) {
    copies[i] = fcntl(sources[i], F_DUPFD_CLOEXEC, 3);
    if (copies[i] < 0) { result = errno; goto cleanup; }
    result = posix_spawn_file_actions_adddup2(&actions, copies[i], i);
    if (result) goto cleanup;
  }
  if (cwd) {
    result = posix_spawn_file_actions_addchdir_np(&actions, cwd);
    if (result) goto cleanup;
  }
  // glibc 2.34+ (Ubuntu 22.04+): close in the child, including descriptors opened
  // concurrently in other threads. A parent-side fd snapshot cannot guarantee this.
  result = posix_spawn_file_actions_addclosefrom_np(&actions, 3);
  if (result) goto cleanup;

  sigset_t empty, defaults;
  sigemptyset(&empty);
  sigfillset(&defaults);
  result = posix_spawnattr_setsigmask(&attributes, &empty);
  if (result) goto cleanup;
  result = posix_spawnattr_setsigdefault(&attributes, &defaults);
  if (result) goto cleanup;
  result = posix_spawnattr_setpgroup(&attributes, 0);
  if (result) goto cleanup;
  result = posix_spawnattr_setflags(&attributes,
    POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF);
  if (result) goto cleanup;
  result = posix_spawn(pid, executable, &actions, &attributes, argv, environment);

cleanup:
  for (int i = 0; i < 3; i++) if (copies[i] >= 0) close(copies[i]);
  posix_spawnattr_destroy(&attributes);
  posix_spawn_file_actions_destroy(&actions);
  return result;
}

int arnes_poll_exit(pid_t pid, int *status, int *signaled) {
  int raw;
  pid_t result;
  do { result = waitpid(pid, &raw, WNOHANG); } while (result < 0 && errno == EINTR);
  if (result <= 0) return result < 0 ? -1 : 0;
  if (!WIFEXITED(raw) && !WIFSIGNALED(raw)) return 0;
  *signaled = WIFSIGNALED(raw);
  *status = *signaled ? WTERMSIG(raw) : WEXITSTATUS(raw);
  return 1;
}
#endif
