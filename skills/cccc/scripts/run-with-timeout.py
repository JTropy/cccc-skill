#!/usr/bin/env python3
"""Run a command with a portable wall-clock timeout."""

import os
import signal
import subprocess
import sys
import time


USAGE = "usage: run-with-timeout.py SECONDS -- COMMAND [ARG ...]"
CLEANUP_GRACE_SECONDS = 2
POLL_INTERVAL_SECONDS = 0.05
# Keep the timeout safely representable as milliseconds on every supported platform.
MAX_TIMEOUT_SECONDS = min(sys.maxsize // 1000, (2**31 - 1) // 1000)


class RunnerInterrupted(Exception):
    """A signal received by the runner while it owns a child process."""

    def __init__(self, signum):
        self.signum = signum


def fail(message):
    print(f"cccc-timeout: {message}", file=sys.stderr)
    return 2


def cleanup_failed(message):
    print(f"cccc-timeout: cleanup failed: {message}", file=sys.stderr)
    return 125


def parse_arguments(argv):
    if len(argv) < 2 or argv[1] != "--":
        return None, None, fail(USAGE)
    if len(argv) < 3:
        return None, None, fail("command is required")
    seconds_text = argv[0]
    if not seconds_text.isascii() or not seconds_text.isdecimal():
        return None, None, fail("seconds must be a non-negative integer")

    significant_digits = seconds_text.lstrip("0") or "0"
    maximum_text = str(MAX_TIMEOUT_SECONDS)
    if (
        len(significant_digits) > len(maximum_text)
        or len(significant_digits) == len(maximum_text)
        and significant_digits > maximum_text
    ):
        return None, None, fail(
            f"seconds must be no greater than {MAX_TIMEOUT_SECONDS}"
        )
    try:
        seconds = int(significant_digits)
    except ValueError:
        return None, None, fail("seconds must be a non-negative integer")
    return seconds, argv[2:], None


def process_group_exists(process_group):
    try:
        os.killpg(process_group, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def bounded_reap(process):
    try:
        process.wait(timeout=CLEANUP_GRACE_SECONDS)
    except subprocess.TimeoutExpired:
        return f"process did not exit within {CLEANUP_GRACE_SECONDS} seconds"
    except OSError as exc:
        return f"could not reap process: {exc}"
    return None


def join_cleanup_errors(*errors):
    return "; ".join(error for error in errors if error)


def stop_posix(process):
    process_group = process.pid
    try:
        os.killpg(process_group, signal.SIGTERM)
    except ProcessLookupError:
        return bounded_reap(process)
    except OSError as exc:
        return join_cleanup_errors(f"SIGTERM failed: {exc}", bounded_reap(process))

    deadline = time.monotonic() + CLEANUP_GRACE_SECONDS
    while process_group_exists(process_group):
        process.poll()
        if not process_group_exists(process_group):
            return bounded_reap(process)
        remaining = max(0, deadline - time.monotonic())
        if remaining == 0:
            break
        time.sleep(min(POLL_INTERVAL_SECONDS, remaining))

    if not process_group_exists(process_group):
        return bounded_reap(process)
    try:
        os.killpg(process_group, signal.SIGKILL)
    except ProcessLookupError:
        return bounded_reap(process)
    except OSError as exc:
        return join_cleanup_errors(f"SIGKILL failed: {exc}", bounded_reap(process))
    return bounded_reap(process)


class WindowsJob:
    """A kill-on-close Windows Job Object, constructed only on Windows."""

    JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE = 0x00002000
    JOB_OBJECT_EXTENDED_LIMIT_INFORMATION = 9

    def __init__(self):
        import ctypes
        from ctypes import wintypes

        self._ctypes = ctypes
        self._kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)

        class IoCounters(ctypes.Structure):
            _fields_ = [(name, ctypes.c_ulonglong) for name in (
                "ReadOperationCount", "WriteOperationCount", "OtherOperationCount",
                "ReadTransferCount", "WriteTransferCount", "OtherTransferCount",
            )]

        class BasicLimitInformation(ctypes.Structure):
            _fields_ = [
                ("PerProcessUserTimeLimit", ctypes.c_longlong),
                ("PerJobUserTimeLimit", ctypes.c_longlong),
                ("LimitFlags", wintypes.DWORD),
                ("MinimumWorkingSetSize", ctypes.c_size_t),
                ("MaximumWorkingSetSize", ctypes.c_size_t),
                ("ActiveProcessLimit", wintypes.DWORD),
                ("Affinity", ctypes.c_size_t),
                ("PriorityClass", wintypes.DWORD),
                ("SchedulingClass", wintypes.DWORD),
            ]

        class ExtendedLimitInformation(ctypes.Structure):
            _fields_ = [
                ("BasicLimitInformation", BasicLimitInformation),
                ("IoInfo", IoCounters),
                ("ProcessMemoryLimit", ctypes.c_size_t),
                ("JobMemoryLimit", ctypes.c_size_t),
                ("PeakProcessMemoryUsed", ctypes.c_size_t),
                ("PeakJobMemoryUsed", ctypes.c_size_t),
            ]

        self._kernel32.CreateJobObjectW.argtypes = [ctypes.c_void_p, wintypes.LPCWSTR]
        self._kernel32.CreateJobObjectW.restype = wintypes.HANDLE
        self._kernel32.SetInformationJobObject.argtypes = [
            wintypes.HANDLE, wintypes.DWORD, ctypes.c_void_p, wintypes.DWORD,
        ]
        self._kernel32.SetInformationJobObject.restype = wintypes.BOOL
        self._kernel32.AssignProcessToJobObject.argtypes = [wintypes.HANDLE, wintypes.HANDLE]
        self._kernel32.AssignProcessToJobObject.restype = wintypes.BOOL
        self._kernel32.CloseHandle.argtypes = [wintypes.HANDLE]
        self._kernel32.CloseHandle.restype = wintypes.BOOL

        self.handle = self._kernel32.CreateJobObjectW(None, None)
        if not self.handle:
            raise ctypes.WinError(ctypes.get_last_error())
        information = ExtendedLimitInformation()
        information.BasicLimitInformation.LimitFlags = self.JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
        if not self._kernel32.SetInformationJobObject(
            self.handle,
            self.JOB_OBJECT_EXTENDED_LIMIT_INFORMATION,
            ctypes.byref(information),
            ctypes.sizeof(information),
        ):
            error = ctypes.WinError(ctypes.get_last_error())
            self.close()
            raise error

    def assign(self, process):
        if not self._kernel32.AssignProcessToJobObject(self.handle, process._handle):
            raise self._ctypes.WinError(self._ctypes.get_last_error())

    def close(self):
        if not self.handle:
            return None
        handle, self.handle = self.handle, None
        if not self._kernel32.CloseHandle(handle):
            return f"could not close Windows Job Object: {self._ctypes.WinError(self._ctypes.get_last_error())}"
        return None


def stop_windows(process, job=None):
    errors = []
    try:
        process.terminate()
    except OSError as exc:
        errors.append(f"terminate failed: {exc}")
    try:
        process.wait(timeout=CLEANUP_GRACE_SECONDS)
    except subprocess.TimeoutExpired:
        try:
            process.kill()
        except OSError as exc:
            errors.append(f"kill failed: {exc}")
        reap_error = bounded_reap(process)
        if reap_error:
            errors.append(reap_error)
    except OSError as exc:
        errors.append(f"could not wait for process: {exc}")

    if job is not None:
        close_error = job.close()
        if close_error:
            errors.append(close_error)
    return join_cleanup_errors(*errors) or None


def install_interrupt_handlers():
    previous = {}

    def interrupted(signum, _frame):
        raise RunnerInterrupted(signum)

    for signum in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
        previous[signum] = signal.getsignal(signum)
        signal.signal(signum, interrupted)
    return previous


def restore_interrupt_handlers(previous):
    for signum, handler in previous.items():
        signal.signal(signum, handler)


def stop_process(process, job=None):
    if os.name == "posix":
        return stop_posix(process)
    if os.name == "nt":
        return stop_windows(process, job)
    try:
        process.terminate()
    except OSError as exc:
        return f"terminate failed: {exc}"
    return bounded_reap(process)


def create_windows_job(process):
    job = None
    try:
        job = WindowsJob()
        job.assign(process)
        return job, None
    except OSError as exc:
        close_error = job.close() if job is not None else None
        cleanup_error = stop_windows(process)
        return None, join_cleanup_errors(
            f"Windows Job Object assignment failed: {exc}", close_error, cleanup_error
        )


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

    job = None
    if os.name == "nt":
        job, error = create_windows_job(process)
        if error:
            return cleanup_failed(error)

    previous_handlers = install_interrupt_handlers() if os.name == "posix" else None
    result = None
    try:
        try:
            result = process.wait() if seconds == 0 else process.wait(timeout=seconds)
        except subprocess.TimeoutExpired:
            print(f"cccc-timeout: command exceeded {seconds} seconds", file=sys.stderr)
            error = stop_process(process, job)
            result = cleanup_failed(error) if error else 124
        except OverflowError:
            error = stop_process(process, job)
            if error:
                result = cleanup_failed(error)
            else:
                result = fail(f"seconds must be no greater than {MAX_TIMEOUT_SECONDS}")
        except RunnerInterrupted as interrupted:
            error = stop_process(process, job)
            result = cleanup_failed(error) if error else -interrupted.signum
    finally:
        if previous_handlers is not None:
            restore_interrupt_handlers(previous_handlers)
        if job is not None:
            close_error = job.close()
            if close_error:
                result = cleanup_failed(close_error)
    return result


def main():
    status = run(sys.argv[1:])
    if status < 0 and os.name == "posix":
        signum = -status
        try:
            os.kill(os.getpid(), signum)
        except OSError:
            return 128 + signum
    return status


if __name__ == "__main__":
    sys.exit(main())
