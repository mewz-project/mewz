#include <errno.h>
#include <sys/types.h>
#include <sys/stat.h>
#include <stdint.h>

int * __errno_location(void) {
  return 0;
}

void _exit(void) {
  while (1) __asm__("hlt");
}


int getpid(void) {
  return 1;
}

int kill(int pid, int sig) {
  errno = EINVAL;
  return -1;
}

int close(int fd) {
  errno = EBADF;
  return -1;
}

off_t lseek(int fd, off_t offset, int whence) {
  errno = EBADF;
  return -1;
}

int open(const char* path, int flags) {
  errno = ENOENT;
  return -1;
}

ssize_t read(int fd, void* buf, size_t count) {
  errno = EBADF;
  return -1;
}

int fstat(int fd, struct stat* buf) {
  errno = EBADF;
  return -1;
}

int isatty(int fd) {
  errno = EBADF;
  return -1;
}
