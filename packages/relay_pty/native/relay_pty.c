// relay-pty: runs a command in a pseudo-terminal for relayd.
//
//   relay-pty <cols> <rows> <cwd> -- <command> [args...]
//
// stdout carries the terminal's raw output. stdin carries frames from
// relayd:  [type u8][length u32 big-endian][payload]
//   type 0  input bytes for the terminal
//   type 1  resize: cols u16, rows u16 (big-endian)
//   type 2  signal: u32 signal number, sent to the child's process group
// The helper exits with the child's exit code (128 + signal if killed).
//
// It exists because forking the Dart VM to call forkpty is unsafe; a tiny
// native process is the portable way to own a PTY. Windows uses ConPTY
// instead (M10).

#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/wait.h>
#include <termios.h>
#include <unistd.h>
#if defined(__APPLE__)
#include <util.h>
#else
#include <pty.h>
#endif

static int write_all(int fd, const unsigned char *buf, size_t len) {
  while (len > 0) {
    ssize_t n = write(fd, buf, len);
    if (n < 0) {
      if (errno == EINTR || errno == EAGAIN) continue;
      return -1;
    }
    buf += n;
    len -= (size_t)n;
  }
  return 0;
}

int main(int argc, char **argv) {
  if (argc < 6 || strcmp(argv[4], "--") != 0) {
    fprintf(stderr, "usage: relay-pty <cols> <rows> <cwd> -- <command> [args...]\n");
    return 2;
  }
  struct winsize ws = {0};
  ws.ws_col = (unsigned short)atoi(argv[1]);
  ws.ws_row = (unsigned short)atoi(argv[2]);
  const char *cwd = argv[3];

  int master = -1;
  pid_t pid = forkpty(&master, NULL, NULL, &ws);
  if (pid < 0) {
    perror("forkpty");
    return 1;
  }
  if (pid == 0) {
    if (cwd[0] != '\0' && chdir(cwd) != 0) {
      perror("chdir");
      _exit(127);
    }
    setenv("TERM", "xterm-256color", 1);
    execvp(argv[5], &argv[5]);
    perror("execvp");
    _exit(127);
  }

  signal(SIGPIPE, SIG_IGN);
  unsigned char hdr[5];
  size_t hdr_len = 0;
  unsigned char *payload = NULL;
  uint32_t need = 0, have = 0;
  int stdin_open = 1;
  unsigned char buf[65536];

  for (;;) {
    struct pollfd fds[2];
    fds[0].fd = master;
    fds[0].events = POLLIN;
    fds[1].fd = stdin_open ? STDIN_FILENO : -1;
    fds[1].events = POLLIN;
    int r = poll(fds, 2, -1);
    if (r < 0) {
      if (errno == EINTR) continue;
      break;
    }
    if (fds[0].revents & (POLLIN | POLLHUP | POLLERR)) {
      ssize_t n = read(master, buf, sizeof buf);
      if (n <= 0) break;  // child closed the terminal
      if (write_all(STDOUT_FILENO, buf, (size_t)n) != 0) break;
    }
    if (stdin_open && (fds[1].revents & (POLLIN | POLLHUP))) {
      ssize_t n = read(STDIN_FILENO, buf, sizeof buf);
      if (n <= 0) {
        stdin_open = 0;  // relayd went away: hang up the terminal
        kill(-pid, SIGHUP);
        continue;
      }
      for (ssize_t i = 0; i < n;) {
        if (hdr_len < 5) {
          hdr[hdr_len++] = buf[i++];
          if (hdr_len == 5) {
            need = ((uint32_t)hdr[1] << 24) | ((uint32_t)hdr[2] << 16) | ((uint32_t)hdr[3] << 8) | hdr[4];
            have = 0;
            free(payload);
            payload = need ? malloc(need) : NULL;
          } else {
            continue;
          }
        }
        if (hdr_len == 5) {
          uint32_t take = (uint32_t)(n - i) < need - have ? (uint32_t)(n - i) : need - have;
          if (take) memcpy(payload + have, buf + i, take);
          have += take;
          i += take;
          if (have == need) {
            if (hdr[0] == 0 && need) {
              write_all(master, payload, need);
            } else if (hdr[0] == 1 && need >= 4) {
              ws.ws_col = (unsigned short)((payload[0] << 8) | payload[1]);
              ws.ws_row = (unsigned short)((payload[2] << 8) | payload[3]);
              ioctl(master, TIOCSWINSZ, &ws);
              kill(-pid, SIGWINCH);
            } else if (hdr[0] == 2 && need >= 4) {
              int sig = (int)(((uint32_t)payload[0] << 24) | ((uint32_t)payload[1] << 16) |
                              ((uint32_t)payload[2] << 8) | payload[3]);
              kill(-pid, sig);
            }
            hdr_len = 0;
          }
        }
      }
    }
  }

  int status = 0;
  waitpid(pid, &status, 0);
  free(payload);
  if (WIFEXITED(status)) return WEXITSTATUS(status);
  if (WIFSIGNALED(status)) return 128 + WTERMSIG(status);
  return 1;
}
