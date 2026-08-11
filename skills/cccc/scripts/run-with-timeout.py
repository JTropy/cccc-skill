#!/usr/bin/env python3
"""Run a command with a portable wall-clock timeout."""

import os
import hashlib
import hmac
import signal
import shutil
import stat
import subprocess
import sys
import time
import uuid


USAGE = (
    "usage: run-with-timeout.py [--status-file ABSENT_PRIVATE_PATH] "
    "[--status-token-file EXISTING_PRIVATE_TOKEN] "
    "SECONDS -- COMMAND [ARG ...]"
)
CLEANUP_GRACE_SECONDS = 2
POLL_INTERVAL_SECONDS = 0.05
# Keep the timeout safely representable as milliseconds on every supported platform.
MAX_TIMEOUT_SECONDS = min(sys.maxsize // 1000, (2**31 - 1) // 1000)
WINDOWS_BOOTSTRAP_WAIT_MS = 10_000
STATUS_VERSION_V1 = "cccc-timeout-result-v1"
STATUS_VERSION_V2 = "cccc-timeout-result-v2"
STATUS_TOKEN_BYTES = 32
WINDOWS_FILE_ATTRIBUTE_REPARSE_POINT = 0x400


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


class StatusFile:
    """A runner-owned, non-inherited file for one trusted outcome record."""

    def __init__(self, fd, identity):
        self.fd = fd
        self.status_dev = identity.st_dev
        self.status_ino = identity.st_ino
        self.token = None

    def authenticate(self, token):
        self.token = token

    def write(self, kind, value=None):
        try:
            value_text = "none" if value is None else str(int(value))
            if self.token is None:
                record = (
                    f"{STATUS_VERSION_V1} kind={kind} value={value_text}\n"
                ).encode("ascii")
            else:
                canonical = (
                    f"{STATUS_VERSION_V2} kind={kind} value={value_text} "
                    f"status_dev={self.status_dev} status_ino={self.status_ino}"
                ).encode("ascii")
                mac = hmac.new(self.token, canonical, hashlib.sha256).hexdigest()
                record = canonical + f" mac={mac}\n".encode("ascii")
            offset = 0
            while offset < len(record):
                written = os.write(self.fd, record[offset:])
                if written <= 0:
                    raise OSError("status file write made no progress")
                offset += written
            os.fsync(self.fd)
        except OSError as exc:
            close_error = self.close()
            return join_cleanup_errors(f"could not persist status file: {exc}", close_error)
        return self.close()

    def close(self):
        if self.fd is None:
            return None
        fd, self.fd = self.fd, None
        try:
            os.close(fd)
        except OSError as exc:
            return f"could not close status file: {exc}"
        return None


def create_status_file(path):
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
    for optional_flag in ("O_NOFOLLOW", "O_CLOEXEC", "O_BINARY"):
        flags |= getattr(os, optional_flag, 0)
    try:
        fd = os.open(path, flags, 0o600)
        os.set_inheritable(fd, False)
        if os.name == "posix":
            os.fchmod(fd, 0o600)
        identity = os.fstat(fd)
        if not stat.S_ISREG(identity.st_mode):
            raise OSError("created status object is not a regular file")
        if os.name == "nt" and (
            getattr(identity, "st_file_attributes", 0)
            & WINDOWS_FILE_ATTRIBUTE_REPARSE_POINT
        ):
            raise OSError("created status object is a reparse point")
    except (OSError, TypeError, ValueError) as exc:
        if "fd" in locals():
            try:
                os.close(fd)
            except OSError:
                pass
        print(f"cccc-timeout: cannot create status file safely: {exc}", file=sys.stderr)
        return None
    return StatusFile(fd, identity)


def parse_status_options(argv):
    if not argv or argv[0] != "--status-file":
        if argv and argv[0] == "--status-token-file":
            return None, None, argv, fail(
                "--status-token-file requires --status-file"
            )
        return None, None, argv, None
    if len(argv) < 2 or not argv[1]:
        return None, None, argv, fail(USAGE)
    status_path = argv[1]
    argv = argv[2:]
    token_path = None
    if argv and argv[0] == "--status-token-file":
        if len(argv) < 2 or not argv[1]:
            return None, None, argv, fail(
                "--status-token-file requires an existing private token path"
            )
        token_path = argv[1]
        argv = argv[2:]
    return status_path, token_path, argv, None


def is_reparse_point(info):
    return bool(
        getattr(info, "st_file_attributes", 0)
        & WINDOWS_FILE_ATTRIBUTE_REPARSE_POINT
    )


def validate_token_identity(info):
    if not stat.S_ISREG(info.st_mode):
        return "status token is not a regular file"
    if os.name == "nt" and is_reparse_point(info):
        return "status token must not be a reparse point"
    if os.name == "posix":
        if info.st_uid != os.geteuid():
            return "status token is not owned by the current user"
        if stat.S_IMODE(info.st_mode) & 0o077:
            return "status token permissions are not private"
        if info.st_nlink != 1:
            return "status token must have exactly one link"
    # Python's standard library exposes no portable Windows DACL inspection.
    # On Windows we still enforce a regular, non-reparse object and identity.
    return None


def same_file_identity(left, right):
    return (left.st_dev, left.st_ino) == (right.st_dev, right.st_ino)


def read_status_token(fd):
    chunks = []
    remaining = STATUS_TOKEN_BYTES + 1
    while remaining:
        chunk = os.read(fd, remaining)
        if not chunk:
            break
        chunks.append(chunk)
        remaining -= len(chunk)
    return b"".join(chunks)


def consume_status_token(path):
    """Read and remove one safe token without ever exposing it to a child."""
    fd = None
    identity = None
    token = None
    try:
        path_identity = os.lstat(path)
        validation_error = validate_token_identity(path_identity)
        if validation_error:
            return None, validation_error, 2

        flags = os.O_RDONLY
        for optional_flag in ("O_NOFOLLOW", "O_CLOEXEC", "O_NONBLOCK", "O_BINARY"):
            flags |= getattr(os, optional_flag, 0)
        fd = os.open(path, flags)
        os.set_inheritable(fd, False)
        identity = os.fstat(fd)
        validation_error = validate_token_identity(identity)
        if validation_error:
            return None, validation_error, 2
        if not same_file_identity(path_identity, identity):
            return None, "status token identity changed while opening", 2
        token = read_status_token(fd)
    except (OSError, TypeError, ValueError) as exc:
        return None, f"cannot read status token safely: {exc}", 2
    finally:
        if fd is not None:
            try:
                os.close(fd)
            except OSError as exc:
                return None, f"could not close status token: {exc}", 125

    try:
        current_identity = os.lstat(path)
        if not same_file_identity(identity, current_identity):
            return None, "status token identity changed before removal", 125
        os.unlink(path)
        try:
            os.lstat(path)
        except FileNotFoundError:
            pass
        else:
            return None, "status token still exists after removal", 125
    except OSError as exc:
        return None, f"could not remove status token: {exc}", 125

    if len(token) != STATUS_TOKEN_BYTES:
        return None, f"status token must contain exactly {STATUS_TOKEN_BYTES} bytes", 2
    return token, None, None


def finish_with_status(status_file, result, kind, value=None):
    if status_file is None:
        return result
    error = status_file.write(kind, value)
    if error:
        return cleanup_failed(error)
    return result


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


def cleanup_posix_after_natural_exit(process):
    """Remove any descendants left in the child's original process group."""
    process_group = process.pid
    if not isinstance(process_group, int) or not process_group_exists(process_group):
        return None
    return stop_posix(process)


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
    status_path, token_path, argv, option_error = parse_status_options(argv)
    if option_error is not None:
        return option_error
    status_file = create_status_file(status_path) if status_path is not None else None
    if status_path is not None and status_file is None:
        return 2
    if token_path is not None:
        token, token_error, token_error_status = consume_status_token(token_path)
        if token_error is not None:
            close_error = status_file.close()
            if close_error:
                return cleanup_failed(join_cleanup_errors(token_error, close_error))
            if token_error_status == 125:
                return cleanup_failed(token_error)
            return fail(token_error)
        status_file.authenticate(token)

    seconds, command, error = parse_arguments(argv)
    if error is not None:
        return finish_with_status(
            status_file, error, "argument-validation"
        )

    options = {}
    if os.name == "posix":
        options["start_new_session"] = True

    interrupt_state = None
    previous_handlers = None
    previous_signal_mask = None
    job = None
    gate = None
    result = None
    result_kind = "runner-internal"
    result_value = None
    process = None
    if os.name == "posix":
        try:
            interrupt_state, previous_handlers, previous_signal_mask = (
                install_interrupt_handlers()
            )
        except (OSError, RuntimeError, ValueError) as exc:
            result = cleanup_failed(f"could not install interrupt handlers: {exc}")
            return finish_with_status(status_file, result, result_kind)
    try:
        try:
            if interrupt_state is not None and interrupt_state.signum is not None:
                raise RunnerInterrupted(interrupt_state.signum)
            if os.name == "nt":
                process, gate, job, error, error_status = launch_windows_bootstrap(command)
                if error:
                    if error_status == 125:
                        result = cleanup_failed(error)
                        result_kind = "cleanup-failure"
                    else:
                        print(f"cccc-timeout: {error}", file=sys.stderr)
                        result = error_status
                        result_kind = "launch-failure"
            else:
                process = subprocess.Popen(command, **options)
            if interrupt_state is not None:
                interrupt_state.process = process
                if interrupt_state.signum is not None:
                    raise RunnerInterrupted(interrupt_state.signum)
            if result is None:
                result = process.wait() if seconds == 0 else process.wait(timeout=seconds)
                if os.name == "posix":
                    cleanup_error = cleanup_posix_after_natural_exit(process)
                    if cleanup_error:
                        result = cleanup_failed(cleanup_error)
                        result_kind = "cleanup-failure"
                    elif result < 0:
                        result_kind = "child-signal"
                        result_value = -result
                    else:
                        result_kind = "child-exit"
                        result_value = result
                else:
                    if not isinstance(result, int) or not 0 <= result <= 0xFFFFFFFF:
                        print(
                            "cccc-timeout: invalid Windows child exit status",
                            file=sys.stderr,
                        )
                        result = 125
                        result_kind = "runner-internal"
                        result_value = None
                    else:
                        result_kind = "child-exit"
                        result_value = result
            if interrupt_state is not None:
                interrupt_state.process = None
        except subprocess.TimeoutExpired:
            print(f"cccc-timeout: command exceeded {seconds} seconds", file=sys.stderr)
            if interrupt_state is not None:
                interrupt_state.process = None
            error = stop_process(process, job)
            if error:
                result = cleanup_failed(error)
                result_kind = "cleanup-failure"
            else:
                result = 124
                result_kind = "wrapper-timeout"
        except OverflowError:
            if interrupt_state is not None:
                interrupt_state.process = None
            error = stop_process(process, job)
            if error:
                result = cleanup_failed(error)
                result_kind = "cleanup-failure"
            else:
                result = fail(f"seconds must be no greater than {MAX_TIMEOUT_SECONDS}")
                result_kind = "argument-validation"
        except RunnerInterrupted as interrupted:
            interrupt_state.process = None
            error = stop_process(process, job) if process is not None else None
            if error:
                result = cleanup_failed(error)
                result_kind = "cleanup-failure"
            else:
                result = -interrupted.signum
                result_kind = "runner-signal"
                result_value = interrupted.signum
        except OSError as exc:
            if process is None:
                if interrupt_state is not None and interrupt_state.signum is not None:
                    result = -interrupt_state.signum
                    result_kind = "runner-signal"
                    result_value = interrupt_state.signum
                else:
                    print(f"cccc-timeout: cannot start command: {exc}", file=sys.stderr)
                    result = 127
                    result_kind = "launch-failure"
            else:
                if interrupt_state is not None:
                    interrupt_state.process = None
                cleanup_error = stop_process(process, job)
                result = cleanup_failed(
                    join_cleanup_errors(f"process lifecycle failed: {exc}", cleanup_error)
                )
                result_kind = "cleanup-failure"
                result_value = None
        except Exception as exc:
            if interrupt_state is not None:
                interrupt_state.process = None
            cleanup_error = stop_process(process, job) if process is not None else None
            if cleanup_error:
                result = cleanup_failed(
                    join_cleanup_errors(f"internal failure: {exc}", cleanup_error)
                )
                result_kind = "cleanup-failure"
            else:
                print(f"cccc-timeout: internal failure: {exc}", file=sys.stderr)
                result = 125
                result_kind = "runner-internal"
            result_value = None
    finally:
        if interrupt_state is not None:
            interrupt_state.process = None
        if previous_handlers is not None:
            restore_error = restore_interrupt_handlers(
                previous_handlers, previous_signal_mask
            )
            if restore_error:
                result = cleanup_failed(restore_error)
                result_kind = "cleanup-failure"
                result_value = None
            elif (
                interrupt_state.signum is not None
                and result_kind != "cleanup-failure"
            ):
                result = -interrupt_state.signum
                result_kind = "runner-signal"
                result_value = interrupt_state.signum
        if job is not None:
            close_error = job.close()
            if close_error:
                result = cleanup_failed(close_error)
                result_kind = "cleanup-failure"
                result_value = None
        if gate is not None:
            close_error = gate.close()
            if close_error:
                result = cleanup_failed(close_error)
                result_kind = "cleanup-failure"
                result_value = None
    return finish_with_status(status_file, result, result_kind, result_value)


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
        # This process is the bootstrap child.  Its native exit status is the
        # target's DWORD and must reach the outer runner without normalization.
        return run_windows_bootstrap(sys.argv[2], parent_pid, sys.argv[5:])
    status = run(sys.argv[1:])
    return exit_with_signal_semantics(status)


def exit_with_signal_semantics(status):
    if os.name == "nt" and status > 255:
        # Preserve the native DWORD in the authenticated status record while
        # using one stable shell transport code for values shells cannot carry.
        return 70
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
