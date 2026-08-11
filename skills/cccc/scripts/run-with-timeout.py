#!/usr/bin/env python3
"""Run a command with a portable wall-clock timeout."""

import os
import signal
import subprocess
import sys
import time


USAGE = "usage: run-with-timeout.py SECONDS -- COMMAND [ARG ...]"


def fail(message):
    print(f"cccc-timeout: {message}", file=sys.stderr)
    return 2


def parse_arguments(argv):
    if len(argv) < 2 or argv[1] != "--":
        return None, None, fail(USAGE)
    if len(argv) < 3:
        return None, None, fail("command is required")
    seconds_text = argv[0]
    if not seconds_text.isascii() or not seconds_text.isdecimal():
        return None, None, fail("seconds must be a non-negative integer")
    return int(seconds_text), argv[2:], None


def process_group_exists(process_group):
    try:
        os.killpg(process_group, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def stop_posix(process):
    process_group = process.pid
    try:
        os.killpg(process_group, signal.SIGTERM)
    except ProcessLookupError:
        pass

    deadline = time.monotonic() + 2
    while process_group_exists(process_group):
        process.poll()
        if not process_group_exists(process_group):
            break
        remaining = max(0, deadline - time.monotonic())
        if remaining == 0:
            break
        time.sleep(min(0.05, remaining))

    if process_group_exists(process_group):
        try:
            os.killpg(process_group, signal.SIGKILL)
        except (ProcessLookupError, PermissionError):
            pass
    process.wait()


def stop_windows(process):
    process.terminate()
    try:
        process.wait(timeout=2)
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait()


def run(argv):
    seconds, command, error = parse_arguments(argv)
    if error is not None:
        return error

    options = {}
    if os.name == "posix":
        options["start_new_session"] = True
    elif os.name == "nt":
        options["creationflags"] = subprocess.CREATE_NEW_PROCESS_GROUP

    try:
        process = subprocess.Popen(command, **options)
    except OSError as exc:
        print(f"cccc-timeout: cannot start command: {exc}", file=sys.stderr)
        return 127

    if seconds == 0:
        return process.wait()
    try:
        return process.wait(timeout=seconds)
    except subprocess.TimeoutExpired:
        print(f"cccc-timeout: command exceeded {seconds} seconds", file=sys.stderr)
        if os.name == "posix":
            stop_posix(process)
        elif os.name == "nt":
            stop_windows(process)
        else:
            process.terminate()
            process.wait()
        return 124


if __name__ == "__main__":
    sys.exit(run(sys.argv[1:]))
