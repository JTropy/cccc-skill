#!/usr/bin/env python3
"""Run a command with a portable wall-clock timeout."""

import os
import signal
import shutil
import subprocess
import sys
import time
import uuid


USAGE = "usage: run-with-timeout.py SECONDS -- COMMAND [ARG ...]"
CLEANUP_GRACE_SECONDS = 2
POLL_INTERVAL_SECONDS = 0.05
# Keep the timeout safely representable as milliseconds on every supported platform.
MAX_TIMEOUT_SECONDS = min(sys.maxsize // 1000, (2**31 - 1) // 1000)
WINDOWS_BOOTSTRAP_WAIT_MS = 10_000


class RunnerInterrupted(Exception):
    """A signal received by the runner while it owns a child process."""

    def __init__(self, signum):
        self.signum = signum


class InterruptState:
    """Records a pre-launch signal until the newly-created child is owned."""

    def __init__(self):
        self.process = None
        self.signum = None


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


def confirm_posix_post_kill(process, process_group):
    """Boundedly prove both the direct child and its process group are gone."""
    deadline = time.monotonic() + CLEANUP_GRACE_SECONDS
    direct_process_gone = False
    process_group_gone = False
    while True:
        direct_process_gone = process.poll() is not None
        process_group_gone = not process_group_exists(process_group)
        if direct_process_gone and process_group_gone:
            return None
        remaining = max(0, deadline - time.monotonic())
        if remaining == 0:
            break
        time.sleep(min(POLL_INTERVAL_SECONDS, remaining))

    errors = []
    if not direct_process_gone:
        errors.append("direct process did not exit after SIGKILL")
    if not process_group_gone:
        errors.append("process group still exists after SIGKILL")
    return join_cleanup_errors(*errors)


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
    return confirm_posix_post_kill(process, process_group)


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
            close_error = self.close()
            if close_error:
                error.cleanup_error = close_error
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


class WindowsGate:
    """A private named event that prevents bootstrap from launching the target early."""

    def __init__(self):
        import ctypes
        from ctypes import wintypes

        self._ctypes = ctypes
        self._kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
        self._kernel32.CreateEventW.argtypes = [
            ctypes.c_void_p, wintypes.BOOL, wintypes.BOOL, wintypes.LPCWSTR,
        ]
        self._kernel32.CreateEventW.restype = wintypes.HANDLE
        self._kernel32.SetEvent.argtypes = [wintypes.HANDLE]
        self._kernel32.SetEvent.restype = wintypes.BOOL
        self._kernel32.CloseHandle.argtypes = [wintypes.HANDLE]
        self._kernel32.CloseHandle.restype = wintypes.BOOL
        self.name = f"Local\\cccc-timeout-{os.getpid()}-{uuid.uuid4().hex}"
        self.handle = self._kernel32.CreateEventW(None, True, False, self.name)
        if not self.handle:
            raise ctypes.WinError(ctypes.get_last_error())

    def set(self):
        if not self._kernel32.SetEvent(self.handle):
            return f"could not release Windows bootstrap gate: {self._ctypes.WinError(self._ctypes.get_last_error())}"
        return None

    def close(self):
        if not self.handle:
            return None
        handle, self.handle = self.handle, None
        if not self._kernel32.CloseHandle(handle):
            return f"could not close Windows bootstrap gate: {self._ctypes.WinError(self._ctypes.get_last_error())}"
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
    state = InterruptState()
    previous = {}
    managed_signals = (signal.SIGINT, signal.SIGTERM, signal.SIGHUP)

    def interrupted(signum, _frame):
        state.signum = signum
        if state.process is not None:
            raise RunnerInterrupted(signum)

    previous_mask = signal.pthread_sigmask(signal.SIG_BLOCK, managed_signals)
    try:
        for signum in managed_signals:
            previous[signum] = signal.getsignal(signum)
            signal.signal(signum, interrupted)
        signal.pthread_sigmask(signal.SIG_UNBLOCK, managed_signals)
    except (OSError, RuntimeError, ValueError) as exc:
        restore_error = restore_interrupt_handlers(previous, previous_mask)
        if restore_error:
            raise OSError(join_cleanup_errors(str(exc), restore_error)) from exc
        raise
    return state, previous, previous_mask


def restore_interrupt_handlers(previous, previous_mask):
    managed_signals = (signal.SIGINT, signal.SIGTERM, signal.SIGHUP)
    errors = []
    try:
        signal.pthread_sigmask(signal.SIG_BLOCK, managed_signals)
    except (OSError, RuntimeError, ValueError) as exc:
        errors.append(f"could not block signals for restoration: {exc}")
    for signum, handler in previous.items():
        try:
            signal.signal(signum, handler)
        except (OSError, RuntimeError, ValueError) as exc:
            errors.append(f"could not restore signal {signum} handler: {exc}")
    try:
        signal.pthread_sigmask(signal.SIG_SETMASK, previous_mask)
    except (OSError, RuntimeError, ValueError) as exc:
        errors.append(f"could not restore signal mask: {exc}")
    return join_cleanup_errors(*errors) or None


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
        return job, None, None
    except OSError as exc:
        cleanup_error = join_cleanup_errors(
            getattr(exc, "cleanup_error", None), stop_windows(process, job)
        )
        return None, f"Windows Job Object assignment failed: {exc}", cleanup_error


def resolve_windows_command(command):
    """Resolve a native Windows executable without invoking command-shell scripts."""
    resolved = shutil.which(command[0])
    if resolved is None:
        return None, f"Windows command not found: {command[0]}"
    extension = os.path.splitext(resolved)[1].lower()
    if extension not in (".exe", ".com"):
        return None, (
            f"Windows command {resolved} is not a native executable; "
            "use an explicit interpreter"
        )
    return [resolved, *command[1:]], None


def launch_windows_bootstrap(command):
    """Start a gated bootstrap, assign it to a Job, then release its target command."""
    if os.name == "nt":
        command, resolution_error = resolve_windows_command(command)
        if resolution_error:
            return None, None, None, resolution_error, 127
    try:
        gate = WindowsGate()
    except OSError as exc:
        return None, None, None, f"could not create Windows bootstrap gate: {exc}", 127
    bootstrap_command = [
        sys.executable,
        os.path.abspath(__file__),
        "--windows-bootstrap",
        gate.name,
        str(os.getpid()),
        "--",
        *command,
    ]
    try:
        process = subprocess.Popen(
            bootstrap_command,
            creationflags=subprocess.CREATE_NEW_PROCESS_GROUP,
        )
    except OSError as exc:
        close_error = gate.close()
        return None, gate, None, join_cleanup_errors(
            f"could not start Windows bootstrap: {exc}", close_error
        ), (125 if close_error else 127)
    job, setup_error, cleanup_error = create_windows_job(process)
    if setup_error:
        cleanup_error = join_cleanup_errors(cleanup_error, gate.close())
        return process, gate, None, join_cleanup_errors(setup_error, cleanup_error), (
            125 if cleanup_error else 127
        )
    release_error = gate.set()
    if release_error:
        cleanup_error = join_cleanup_errors(stop_windows(process, job), gate.close())
        return process, gate, None, join_cleanup_errors(release_error, cleanup_error), (
            125 if cleanup_error else 127
        )
    return process, gate, job, None, None


def wait_for_windows_bootstrap_gate(event_name, parent_pid):
    """Return gate, parent, or an error after waiting on the immutable parent handle."""
    import ctypes
    from ctypes import wintypes

    synchronize = 0x00100000
    error_invalid_parameter = 87
    wait_object_0 = 0
    wait_timeout = 0x00000102
    wait_failed = 0xFFFFFFFF
    kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
    kernel32.OpenEventW.argtypes = [wintypes.DWORD, wintypes.BOOL, wintypes.LPCWSTR]
    kernel32.OpenEventW.restype = wintypes.HANDLE
    kernel32.OpenProcess.argtypes = [wintypes.DWORD, wintypes.BOOL, wintypes.DWORD]
    kernel32.OpenProcess.restype = wintypes.HANDLE
    kernel32.WaitForMultipleObjects.argtypes = [
        wintypes.DWORD, ctypes.POINTER(wintypes.HANDLE), wintypes.BOOL, wintypes.DWORD,
    ]
    kernel32.WaitForMultipleObjects.restype = wintypes.DWORD
    kernel32.CloseHandle.argtypes = [wintypes.HANDLE]
    kernel32.CloseHandle.restype = wintypes.BOOL

    event = kernel32.OpenEventW(synchronize, False, event_name)
    if not event:
        return f"could not open Windows bootstrap gate: {ctypes.WinError(ctypes.get_last_error())}"
    parent = kernel32.OpenProcess(synchronize, False, parent_pid)
    if not parent:
        error = ctypes.get_last_error()
        kernel32.CloseHandle(event)
        if error == error_invalid_parameter:
            return "parent"
        return f"could not open parent process (Win32 error {error})"
    try:
        handles = (wintypes.HANDLE * 2)(event, parent)
        result = kernel32.WaitForMultipleObjects(
            2, handles, False, WINDOWS_BOOTSTRAP_WAIT_MS
        )
        if result == wait_object_0:
            return "gate"
        if result == wait_object_0 + 1:
            return "parent"
        if result == wait_timeout:
            return "bootstrap gate wait timed out"
        if result == wait_failed:
            return f"bootstrap gate wait failed: {ctypes.WinError(ctypes.get_last_error())}"
        return f"bootstrap gate wait returned {result}"
    finally:
        kernel32.CloseHandle(parent)
        kernel32.CloseHandle(event)


def run_windows_bootstrap(event_name, parent_pid, command):
    wait_result = wait_for_windows_bootstrap_gate(event_name, parent_pid)
    if wait_result == "parent":
        return 0
    if wait_result != "gate":
        print(f"cccc-timeout: bootstrap {wait_result}", file=sys.stderr)
        return 127
    try:
        return subprocess.Popen(command).wait()
    except OSError as exc:
        print(f"cccc-timeout: bootstrap cannot start command: {exc}", file=sys.stderr)
        return 127


def run(argv):
    seconds, command, error = parse_arguments(argv)
    if error is not None:
        return error

    options = {}
    if os.name == "posix":
        options["start_new_session"] = True

    interrupt_state = None
    previous_handlers = None
    previous_signal_mask = None
    job = None
    gate = None
    result = None
    process = None
    if os.name == "posix":
        try:
            interrupt_state, previous_handlers, previous_signal_mask = (
                install_interrupt_handlers()
            )
        except (OSError, RuntimeError, ValueError) as exc:
            return cleanup_failed(f"could not install interrupt handlers: {exc}")
    try:
        try:
            if interrupt_state is not None and interrupt_state.signum is not None:
                raise RunnerInterrupted(interrupt_state.signum)
            if os.name == "nt":
                process, gate, job, error, error_status = launch_windows_bootstrap(command)
                if error:
                    if error_status == 125:
                        result = cleanup_failed(error)
                    else:
                        print(f"cccc-timeout: {error}", file=sys.stderr)
                        result = error_status
            else:
                process = subprocess.Popen(command, **options)
            if interrupt_state is not None:
                interrupt_state.process = process
                if interrupt_state.signum is not None:
                    raise RunnerInterrupted(interrupt_state.signum)
            if result is None:
                result = process.wait() if seconds == 0 else process.wait(timeout=seconds)
            if interrupt_state is not None:
                interrupt_state.process = None
        except subprocess.TimeoutExpired:
            print(f"cccc-timeout: command exceeded {seconds} seconds", file=sys.stderr)
            if interrupt_state is not None:
                interrupt_state.process = None
            error = stop_process(process, job)
            result = cleanup_failed(error) if error else 124
        except OverflowError:
            if interrupt_state is not None:
                interrupt_state.process = None
            error = stop_process(process, job)
            if error:
                result = cleanup_failed(error)
            else:
                result = fail(f"seconds must be no greater than {MAX_TIMEOUT_SECONDS}")
        except RunnerInterrupted as interrupted:
            interrupt_state.process = None
            error = stop_process(process, job) if process is not None else None
            result = cleanup_failed(error) if error else -interrupted.signum
        except OSError as exc:
            if process is None:
                if interrupt_state is not None and interrupt_state.signum is not None:
                    result = -interrupt_state.signum
                else:
                    print(f"cccc-timeout: cannot start command: {exc}", file=sys.stderr)
                    result = 127
            else:
                if interrupt_state is not None:
                    interrupt_state.process = None
                cleanup_error = stop_process(process, job)
                result = cleanup_failed(
                    join_cleanup_errors(f"process lifecycle failed: {exc}", cleanup_error)
                )
    finally:
        if interrupt_state is not None:
            interrupt_state.process = None
        if previous_handlers is not None:
            restore_error = restore_interrupt_handlers(
                previous_handlers, previous_signal_mask
            )
            if restore_error:
                result = cleanup_failed(restore_error)
            elif interrupt_state.signum is not None and result != 125:
                result = -interrupt_state.signum
        if job is not None:
            close_error = job.close()
            if close_error:
                result = cleanup_failed(close_error)
        if gate is not None:
            close_error = gate.close()
            if close_error:
                result = cleanup_failed(close_error)
    return result


def main():
    if len(sys.argv) >= 5 and sys.argv[1] == "--windows-bootstrap":
        if os.name != "nt" or sys.argv[4] != "--" or len(sys.argv) < 6:
            print("cccc-timeout: invalid Windows bootstrap invocation", file=sys.stderr)
            return 127
        try:
            parent_pid = int(sys.argv[3])
        except ValueError:
            print("cccc-timeout: invalid Windows bootstrap parent pid", file=sys.stderr)
            return 127
        return exit_with_signal_semantics(
            run_windows_bootstrap(sys.argv[2], parent_pid, sys.argv[5:])
        )
    status = run(sys.argv[1:])
    return exit_with_signal_semantics(status)


def exit_with_signal_semantics(status):
    if status < 0 and os.name == "posix":
        signum = -status
        try:
            signal.signal(signum, signal.SIG_DFL)
        except (OSError, RuntimeError, ValueError):
            # SIGKILL/SIGSTOP cannot have a disposition, but must still be resent.
            pass
        if hasattr(signal, "pthread_sigmask"):
            try:
                signal.pthread_sigmask(signal.SIG_UNBLOCK, {signum})
            except (OSError, RuntimeError, ValueError):
                pass
        try:
            os.kill(os.getpid(), signum)
        except OSError:
            return 128 + signum
    return status


if __name__ == "__main__":
    sys.exit(main())
