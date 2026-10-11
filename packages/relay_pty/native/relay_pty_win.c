// relay-pty for Windows (M10-02): the same contract as relay_pty.c, on
// ConPTY (Windows 10 1809+).
//
//   relay-pty.exe <cols> <rows> <cwd> -- <command> [args...]
//
// Stdin carries frames: [type u8][length u32 BE][payload]
//   0 input   bytes for the terminal
//   1 resize  cols u16 BE, rows u16 BE
//   2 signal  u32 BE: 2 (interrupt) sends Ctrl+C; anything else ends the tree
// Stdout is the terminal's raw output. Exit code: the command's.
//
// The command runs in a Job Object that dies with this helper, so closing
// a terminal ends everything started in it. Build: cl /O2 relay_pty_win.c
// or x86_64-w64-mingw32-gcc -O2 -municode relay_pty_win.c -o relay-pty.exe

#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#ifndef _WIN32_WINNT
#define _WIN32_WINNT 0x0A00
#endif
#include <windows.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <wchar.h>

#ifndef PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE
#define PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE 0x00020016
#endif

// ConPTY is loaded from kernel32 at run time: any toolchain's headers will
// do, and Windows before 1809 gets a clear message instead of a load error.
typedef void *RelayHPCON;
typedef HRESULT(WINAPI *CreatePC)(COORD, HANDLE, HANDLE, DWORD, RelayHPCON *);
typedef HRESULT(WINAPI *ResizePC)(RelayHPCON, COORD);
typedef void(WINAPI *ClosePC)(RelayHPCON);
static CreatePC create_pc;
static ResizePC resize_pc;
static ClosePC close_pc;

static HANDLE out_read, in_write, job, proc;
static int debug; // RELAY_PTY_DEBUG=1: frames and writes on stderr

static void trace(const char *what, DWORD a, DWORD b) {
  if (!debug) return;
  fprintf(stderr, "relay-pty: %s %lu %lu (err %lu)\n", what, (unsigned long)a, (unsigned long)b, (unsigned long)GetLastError());
  fflush(stderr);
}
static RelayHPCON pty;

// MSVCRT quoting for one argument of a command line.
static void append_arg(wchar_t **buf, size_t *len, size_t *cap, const wchar_t *arg) {
  size_t need = *len + wcslen(arg) * 2 + 4;
  if (need > *cap) {
    *cap = need * 2;
    *buf = (wchar_t *)realloc(*buf, *cap * sizeof(wchar_t));
  }
  wchar_t *b = *buf;
  if (*len) b[(*len)++] = L' ';
  int quote = arg[0] == 0 || wcspbrk(arg, L" \t\"") != NULL;
  if (quote) b[(*len)++] = L'"';
  for (const wchar_t *p = arg;; p++) {
    size_t slashes = 0;
    while (*p == L'\\') {
      slashes++;
      p++;
    }
    if (*p == 0) {
      for (size_t i = 0; i < (quote ? slashes * 2 : slashes); i++) b[(*len)++] = L'\\';
      break;
    }
    if (*p == L'"') {
      for (size_t i = 0; i < slashes * 2 + 1; i++) b[(*len)++] = L'\\';
      b[(*len)++] = L'"';
    } else {
      for (size_t i = 0; i < slashes; i++) b[(*len)++] = L'\\';
      b[(*len)++] = *p;
    }
  }
  if (quote) b[(*len)++] = L'"';
  b[*len] = 0;
}

// Our stdin/stdout come from the parent (Dart), which may open its pipe
// ends for overlapped I/O; a synchronous ReadFile/WriteFile on such a
// handle is undefined (it can "complete" with nothing read). So both go
// through an OVERLAPPED and wait for the result, which works whichever way
// the handle was opened. Returns bytes moved, 0 on end/error.
static DWORD io(HANDLE h, void *buf, DWORD n, int write) {
  OVERLAPPED ov;
  ZeroMemory(&ov, sizeof ov);
  ov.hEvent = CreateEventW(NULL, TRUE, FALSE, NULL);
  DWORD done = 0;
  BOOL ok = write ? WriteFile(h, buf, n, &done, &ov) : ReadFile(h, buf, n, &done, &ov);
  if (!ok && GetLastError() == ERROR_IO_PENDING) ok = GetOverlappedResult(h, &ov, &done, TRUE);
  else if (ok) GetOverlappedResult(h, &ov, &done, TRUE);
  CloseHandle(ov.hEvent);
  return ok ? done : 0;
}

// A zero-byte write on the other end arrives as a zero-byte read; only a
// failed read (broken pipe) means the input has closed.
static int read_full(HANDLE h, void *buf, DWORD n) {
  BYTE *p = (BYTE *)buf;
  while (n > 0) {
    SetLastError(0);
    DWORD got = io(h, p, n, 0);
    if (got == 0) {
      DWORD err = GetLastError();
      if (err == ERROR_BROKEN_PIPE || err == ERROR_HANDLE_EOF || err == ERROR_NO_DATA || err == ERROR_INVALID_HANDLE) return 0;
      if (err != 0) return 0;
      continue;
    }
    p += got;
    n -= got;
  }
  return 1;
}

static int write_all(HANDLE h, const BYTE *p, DWORD n) {
  while (n > 0) {
    DWORD put = io(h, (void *)p, n, 1);
    if (put == 0) return 0;
    p += put;
    n -= put;
  }
  return 1;
}

static DWORD WINAPI pump_output(LPVOID unused) {
  (void)unused;
  HANDLE out = GetStdHandle(STD_OUTPUT_HANDLE);
  BYTE buf[16384];
  DWORD got;
  // out_read is our own anonymous pipe (synchronous); stdout is the parent's.
  while (ReadFile(out_read, buf, sizeof buf, &got, NULL)) {
    if (got == 0) continue;
    if (!write_all(out, buf, got)) break;
  }
  return 0;
}

static DWORD WINAPI pump_input(LPVOID unused) {
  (void)unused;
  HANDLE in = GetStdHandle(STD_INPUT_HANDLE);
  for (;;) {
    BYTE head[5];
    if (!read_full(in, head, 5)) break;
    DWORD len = ((DWORD)head[1] << 24) | ((DWORD)head[2] << 16) | ((DWORD)head[3] << 8) | head[4];
    trace("frame", head[0], len);
    BYTE *payload = len ? (BYTE *)malloc(len) : NULL;
    if (len && (!payload || !read_full(in, payload, len))) {
      free(payload);
      break;
    }
    DWORD put;
    switch (head[0]) {
    case 0:
      if (len) {
        BOOL ok = WriteFile(in_write, payload, len, &put, NULL);
        trace(ok ? "input written" : "input write failed", len, put);
      }
      break;
    case 1:
      if (len >= 4) {
        COORD size = {(SHORT)((payload[0] << 8) | payload[1]), (SHORT)((payload[2] << 8) | payload[3])};
        resize_pc(pty, size);
      }
      break;
    case 2:
      if (len >= 4) {
        DWORD sig = ((DWORD)payload[0] << 24) | ((DWORD)payload[1] << 16) | ((DWORD)payload[2] << 8) | payload[3];
        if (sig == 2) {
          WriteFile(in_write, "\x03", 1, &put, NULL);
        } else {
          TerminateJobObject(job, 128 + sig);
        }
      }
      break;
    default:
      break;
    }
    free(payload);
  }
  trace("stdin closed", 0, 0);
  // Stdin closed: the terminal is gone; end everything in it.
  TerminateJobObject(job, 129);
  return 0;
}

int wmain(int argc, wchar_t **argv) {
  if (argc < 6 || wcscmp(argv[4], L"--") != 0) {
    fwprintf(stderr, L"usage: relay-pty <cols> <rows> <cwd> -- <command> [args...]\n");
    return 2;
  }
  debug = GetEnvironmentVariableW(L"RELAY_PTY_DEBUG", NULL, 0) > 0;
  COORD size = {(SHORT)_wtoi(argv[1]), (SHORT)_wtoi(argv[2])};
  if (size.X <= 0) size.X = 100;
  if (size.Y <= 0) size.Y = 30;
  const wchar_t *cwd = argv[3][0] ? argv[3] : NULL;

  HANDLE in_read, out_write;
  SECURITY_ATTRIBUTES sa = {sizeof sa, NULL, FALSE};
  if (!CreatePipe(&in_read, &in_write, &sa, 0) || !CreatePipe(&out_read, &out_write, &sa, 0)) {
    fwprintf(stderr, L"relay-pty: CreatePipe failed (%lu)\n", GetLastError());
    return 1;
  }
  HMODULE k32 = GetModuleHandleW(L"kernel32.dll");
  create_pc = (CreatePC)(void *)GetProcAddress(k32, "CreatePseudoConsole");
  resize_pc = (ResizePC)(void *)GetProcAddress(k32, "ResizePseudoConsole");
  close_pc = (ClosePC)(void *)GetProcAddress(k32, "ClosePseudoConsole");
  if (!create_pc || !resize_pc || !close_pc) {
    fwprintf(stderr, L"relay-pty: this Windows has no ConPTY; Relay's terminals need Windows 10 1809 or later\n");
    return 1;
  }
  HRESULT hr = create_pc(size, in_read, out_write, 0, &pty);
  if (FAILED(hr)) {
    fwprintf(stderr, L"relay-pty: CreatePseudoConsole failed (0x%08lx); needs Windows 10 1809 or later\n", (unsigned long)hr);
    return 1;
  }
  // The pseudoconsole holds its own handles to these now.
  CloseHandle(in_read);
  CloseHandle(out_write);

  job = CreateJobObjectW(NULL, NULL);
  JOBOBJECT_EXTENDED_LIMIT_INFORMATION limits;
  ZeroMemory(&limits, sizeof limits);
  limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
  SetInformationJobObject(job, JobObjectExtendedLimitInformation, &limits, sizeof limits);

  size_t attr_size = 0;
  InitializeProcThreadAttributeList(NULL, 1, 0, &attr_size);
  STARTUPINFOEXW si;
  ZeroMemory(&si, sizeof si);
  si.StartupInfo.cb = sizeof si;
  si.lpAttributeList = (LPPROC_THREAD_ATTRIBUTE_LIST)malloc(attr_size);
  if (!InitializeProcThreadAttributeList(si.lpAttributeList, 1, 0, &attr_size) ||
      !UpdateProcThreadAttribute(si.lpAttributeList, 0, PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE, pty, sizeof pty, NULL, NULL)) {
    fwprintf(stderr, L"relay-pty: attribute list failed (%lu)\n", GetLastError());
    return 1;
  }

  wchar_t *cmd = NULL;
  size_t len = 0, cap = 0;
  for (int i = 5; i < argc; i++) append_arg(&cmd, &len, &cap, argv[i]);
  SetEnvironmentVariableW(L"TERM", L"xterm-256color");

  PROCESS_INFORMATION pi;
  if (!CreateProcessW(NULL, cmd, NULL, NULL, FALSE, EXTENDED_STARTUPINFO_PRESENT | CREATE_SUSPENDED | CREATE_UNICODE_ENVIRONMENT,
                      NULL, cwd, &si.StartupInfo, &pi)) {
    DWORD err = GetLastError();
    char msg[512];
    int n = snprintf(msg, sizeof msg, "relay-pty: could not start the command (error %lu)\r\n", err);
    write_all(GetStdHandle(STD_OUTPUT_HANDLE), (const BYTE *)msg, (DWORD)n);
    return 127;
  }
  AssignProcessToJobObject(job, pi.hProcess);
  ResumeThread(pi.hThread);
  CloseHandle(pi.hThread);
  proc = pi.hProcess;

  HANDLE reader = CreateThread(NULL, 0, pump_output, NULL, 0, NULL);
  CreateThread(NULL, 0, pump_input, NULL, 0, NULL);

  WaitForSingleObject(proc, INFINITE);
  DWORD code = 1;
  GetExitCodeProcess(proc, &code);
  // Closing the pseudoconsole flushes the last output and ends the reader.
  close_pc(pty);
  WaitForSingleObject(reader, 3000);
  CloseHandle(job);
  return (int)code;
}
