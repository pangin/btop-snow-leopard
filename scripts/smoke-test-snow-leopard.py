#!/usr/bin/python

from __future__ import print_function

import errno
import fcntl
import json
import os
import pty
import select
import signal
import struct
import sys
import termios
import time


LOG_LIMIT = 8 * 1024 * 1024
MAX_OUTPUT_BYTES = 4 * 1024 * 1024


def usage():
    print("usage: %s BINARY CONFIG_ROOT OUTPUT_LOG [SECONDS]" % sys.argv[0], file=sys.stderr)
    return 64


def reap(pid):
    waited, status = os.waitpid(pid, os.WNOHANG)
    if waited == 0:
        return None
    if os.WIFEXITED(status):
        return os.WEXITSTATUS(status)
    if os.WIFSIGNALED(status):
        return 128 + os.WTERMSIG(status)
    return 125


def drain(master_fd, output, byte_count, timeout):
    ready, _, _ = select.select([master_fd], [], [], timeout)
    if not ready:
        return byte_count
    for _ in range(64):
        try:
            data = os.read(master_fd, 65536)
        except OSError as error:
            if error.errno in (errno.EAGAIN, errno.EWOULDBLOCK, errno.EIO, errno.EINTR):
                break
            raise
        if not data:
            break
        if byte_count < LOG_LIMIT:
            remaining = LOG_LIMIT - byte_count
            output.write(data[:remaining])
        byte_count += len(data)
    output.flush()
    return byte_count


def main():
    if len(sys.argv) not in (4, 5):
        return usage()

    binary = os.path.abspath(sys.argv[1])
    config_root = os.path.abspath(sys.argv[2])
    output_log = os.path.abspath(sys.argv[3])
    run_seconds = float(sys.argv[4]) if len(sys.argv) == 5 else 8.0

    if not os.path.isfile(binary) or not os.access(binary, os.X_OK):
        print("executable not found: %s" % binary, file=sys.stderr)
        return 66

    for directory in (config_root, os.path.dirname(output_log)):
        if directory and not os.path.isdir(directory):
            os.makedirs(directory)

    window_size = struct.pack("HHHH", 40, 140, 0, 0)
    pid, master_fd = pty.fork()
    if pid == 0:
        os.environ["TERM"] = "xterm-256color"
        os.environ["LANG"] = "en_US.UTF-8"
        os.environ["LC_ALL"] = "en_US.UTF-8"
        os.environ["XDG_CONFIG_HOME"] = config_root
        fcntl.ioctl(0, termios.TIOCSWINSZ, window_size)
        try:
            os.execv(binary, [binary])
        except Exception as error:
            print("exec failed: %s" % error, file=sys.stderr)
            os._exit(127)

    fcntl.ioctl(master_fd, termios.TIOCSWINSZ, window_size)
    descriptor_flags = fcntl.fcntl(master_fd, fcntl.F_GETFL)
    fcntl.fcntl(master_fd, fcntl.F_SETFL, descriptor_flags | os.O_NONBLOCK)
    byte_count = 0
    exit_code = None
    quit_sent = False
    started = time.time()

    with open(output_log, "wb") as output:
        while time.time() - started < run_seconds:
            byte_count = drain(master_fd, output, byte_count, 0.25)
            exit_code = reap(pid)
            if exit_code is not None:
                break

        if exit_code is None:
            os.write(master_fd, b"q")
            quit_sent = True
            quit_deadline = time.time() + 8.0
            while time.time() < quit_deadline:
                byte_count = drain(master_fd, output, byte_count, 0.25)
                exit_code = reap(pid)
                if exit_code is not None:
                    break

    if exit_code is None:
        os.kill(pid, signal.SIGTERM)
        term_deadline = time.time() + 2.0
        while time.time() < term_deadline:
            exit_code = reap(pid)
            if exit_code is not None:
                break
            time.sleep(0.1)

    if exit_code is None:
        os.kill(pid, signal.SIGKILL)
        _, status = os.waitpid(pid, 0)
        exit_code = 128 + os.WTERMSIG(status)

    os.close(master_fd)
    result = {
        "binary": binary,
        "bytes": byte_count,
        "exit_code": exit_code,
        "seconds": round(time.time() - started, 2),
    }
    print(json.dumps(result, sort_keys=True))

    if exit_code != 0:
        print("TUI exited with status %s" % exit_code, file=sys.stderr)
        return 1
    if not quit_sent:
        print("TUI exited before the quit-key test", file=sys.stderr)
        return 1
    if byte_count < 4096:
        print("TUI produced too little terminal output", file=sys.stderr)
        return 1
    if byte_count > MAX_OUTPUT_BYTES:
        print("TUI produced excessive terminal output", file=sys.stderr)
        return 1

    with open(output_log, "rb") as captured:
        screen = captured.read(LOG_LIMIT)
    if b"No boxes shown!" in screen:
        print("TUI did not render its configured boxes", file=sys.stderr)
        return 1
    for marker in (b"cpu", b"mem", b"net", b"proc"):
        if marker not in screen:
            print("TUI output is missing the %s box" % marker, file=sys.stderr)
            return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
