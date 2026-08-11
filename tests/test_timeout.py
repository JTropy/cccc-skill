"""Integration tests for the portable timeout runner."""

import os
from pathlib import Path
import signal
import shutil
import io
import ctypes
import hashlib
import hmac
import json
import subprocess
import sys
import tempfile
import time
import unittest
from unittest import mock
import importlib.util


ROOT = Path(__file__).resolve().parents[1]
RUNNER = ROOT / "skills" / "cccc" / "scripts" / "run-with-timeout.py"
RUNNER_SPEC = importlib.util.spec_from_file_location("run_with_timeout", RUNNER)
RUNNER_MODULE = importlib.util.module_from_spec(RUNNER_SPEC)
RUNNER_SPEC.loader.exec_module(RUNNER_MODULE)


def command(*args):
    return [sys.executable, str(RUNNER), *args]


def child(code):
    return [sys.executable, "-c", code]


def pid_is_gone(pid):
    if os.name == "nt":
        return windows_pid_is_gone(pid)
    if os.name != "posix":
        raise RuntimeError(f"unsupported process probe platform: {os.name}")
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return True
    except PermissionError:
        return False
    return False


def windows_pid_is_gone(pid):
    """Check a Windows PID without calling os.kill (which terminates processes)."""
    from ctypes import wintypes

    process_query_limited_information = 0x1000
    still_active = 259
    error_invalid_parameter = 87
    kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
    kernel32.OpenProcess.argtypes = [wintypes.DWORD, wintypes.BOOL, wintypes.DWORD]
    kernel32.OpenProcess.restype = wintypes.HANDLE
    kernel32.GetExitCodeProcess.argtypes = [wintypes.HANDLE, ctypes.POINTER(wintypes.DWORD)]
    kernel32.GetExitCodeProcess.restype = wintypes.BOOL
    kernel32.CloseHandle.argtypes = [wintypes.HANDLE]
    kernel32.CloseHandle.restype = wintypes.BOOL

    handle = kernel32.OpenProcess(process_query_limited_information, False, pid)
    if not handle:
        return ctypes.get_last_error() == error_invalid_parameter
    try:
        exit_code = wintypes.DWORD()
        if not kernel32.GetExitCodeProcess(handle, ctypes.byref(exit_code)):
            return False
        return exit_code.value != still_active
    finally:
        kernel32.CloseHandle(handle)


class WindowsPidProbeTests(unittest.TestCase):
    def test_windows_pid_probe_never_calls_os_kill(self):
        with mock.patch.object(os, "name", "nt"), \
             mock.patch.object(sys.modules[__name__], "windows_pid_is_gone", return_value=True), \
             mock.patch.object(os, "kill") as kill:
            self.assertTrue(pid_is_gone(456))

        kill.assert_not_called()

    def test_windows_probe_queries_exit_code_and_closes_handle(self):
        kernel32 = mock.Mock()
        kernel32.OpenProcess.return_value = 123
        kernel32.CloseHandle.return_value = True

        def get_exit_code(_handle, exit_code):
            exit_code._obj.value = 259  # STILL_ACTIVE
            return True

        kernel32.GetExitCodeProcess.side_effect = get_exit_code
        with mock.patch.object(ctypes, "WinDLL", return_value=kernel32, create=True):
            self.assertFalse(windows_pid_is_gone(456))

        kernel32.OpenProcess.assert_called_once()
        kernel32.GetExitCodeProcess.assert_called_once()
        kernel32.CloseHandle.assert_called_once_with(123)


class TimeoutRunnerTests(unittest.TestCase):
    def run_runner(self, seconds, *program, timeout=10):
        return subprocess.run(
            command(str(seconds), "--", *program),
            capture_output=True,
            timeout=timeout,
        )

    def run_runner_with_status(self, status_file, seconds, *program, timeout=10):
        return subprocess.run(
            command(
                "--status-file", str(status_file), str(seconds), "--", *program
            ),
            capture_output=True,
            timeout=timeout,
        )

    def run_runner_with_authenticated_status(
        self, status_file, token_file, seconds, *program, timeout=10
    ):
        return subprocess.run(
            command(
                "--status-file",
                str(status_file),
                "--status-token-file",
                str(token_file),
                str(seconds),
                "--",
                *program,
            ),
            capture_output=True,
            timeout=timeout,
        )

    def assert_status(self, status_file, kind, value):
        expected = f"cccc-timeout-result-v1 kind={kind} value={value}\n"
        self.assertEqual(status_file.read_bytes(), expected.encode("ascii"))

    def assert_authenticated_status(self, status_file, token, kind, value):
        status_identity = status_file.stat()
        canonical = (
            f"cccc-timeout-result-v2 kind={kind} value={value} "
            f"status_dev={status_identity.st_dev} "
            f"status_ino={status_identity.st_ino}"
        )
        mac = hmac.new(
            token, canonical.encode("ascii"), hashlib.sha256
        ).hexdigest()
        record = status_file.read_text(encoding="ascii")
        self.assertEqual(record, f"{canonical} mac={mac}\n")
        self.assertNotIn(token.hex(), record)

    def test_authenticated_status_consumes_private_token_before_child_launch(self):
        with tempfile.TemporaryDirectory() as directory:
            directory = Path(directory)
            status_file = directory / "status"
            token_file = directory / "token"
            token = bytes(range(32))
            token_file.write_bytes(token)
            if os.name == "posix":
                token_file.chmod(0o600)
            child_state = directory / "child-state.json"
            child_probe = (
                "from pathlib import Path; import json, os, sys; "
                "Path(sys.argv[1]).write_text(json.dumps({"
                "'argv': sys.argv, 'env': dict(os.environ), "
                "'token_exists': Path(sys.argv[2]).exists()}), encoding='utf-8')"
            )

            result = self.run_runner_with_authenticated_status(
                status_file,
                token_file,
                2,
                *child(child_probe),
                str(child_state),
                str(token_file),
            )

            self.assertEqual(result.returncode, 0, result.stderr.decode(errors="replace"))
            self.assertFalse(token_file.exists())
            observed = child_state.read_bytes()
            if token in observed or token.hex().encode("ascii") in observed:
                self.fail("authenticated token was visible in child argv or environment")
            self.assertFalse(
                json.loads(observed.decode("utf-8"))["token_exists"]
            )
            self.assert_authenticated_status(status_file, token, "child-exit", 0)

    def test_authenticated_status_rejects_unsafe_or_malformed_token_without_launch(self):
        with tempfile.TemporaryDirectory() as directory:
            directory = Path(directory)
            sentinel = directory / "started"
            cases = []
            missing = directory / "missing-token"
            cases.append(("missing", missing))
            short = directory / "short-token"
            short.write_bytes(b"x" * 31)
            cases.append(("short", short))
            long = directory / "long-token"
            long.write_bytes(b"x" * 33)
            cases.append(("long", long))
            if os.name == "posix":
                unsafe_mode = directory / "unsafe-mode-token"
                unsafe_mode.write_bytes(b"x" * 32)
                unsafe_mode.chmod(0o644)
                cases.append(("unsafe-mode", unsafe_mode))
                token_target = directory / "token-target"
                token_target.write_bytes(b"x" * 32)
                token_target.chmod(0o600)
                token_link = directory / "token-link"
                token_link.symlink_to(token_target)
                cases.append(("symlink", token_link))
                token_fifo = directory / "token-fifo"
                os.mkfifo(token_fifo)
                cases.append(("fifo", token_fifo))

            for name, token_file in cases:
                with self.subTest(name=name):
                    status_file = directory / f"status-{name}"
                    result = self.run_runner_with_authenticated_status(
                        status_file,
                        token_file,
                        2,
                        *child(
                            "from pathlib import Path; import sys; "
                            "Path(sys.argv[1]).touch()"
                        ),
                        str(sentinel),
                        timeout=4,
                    )
                    self.assertNotEqual(result.returncode, 0)
                    self.assertFalse(sentinel.exists())
                    self.assertIn(b"token", result.stderr.lower())

    def test_token_option_requires_status_file_and_exact_pairing(self):
        with tempfile.TemporaryDirectory() as directory:
            token_file = Path(directory) / "token"
            token_file.write_bytes(b"x" * 32)
            if os.name == "posix":
                token_file.chmod(0o600)
            invalid = [
                ["--status-token-file", str(token_file), "1", "--", *child("pass")],
                ["--status-file", str(Path(directory) / "status"), "--status-token-file"],
            ]
            for arguments in invalid:
                with self.subTest(arguments=arguments):
                    result = subprocess.run(command(*arguments), capture_output=True, timeout=4)
                    self.assertEqual(result.returncode, 2)
                    self.assertTrue(result.stderr.strip())
                    self.assertIn(b"status-token-file", result.stderr)

    def test_rejects_bad_invocation(self):
        invalid = [
            [],
            ["1"],
            ["1", "--"],
            ["-1", "--", *child("pass")],
            ["1.5", "--", *child("pass")],
            ["nope", "--", *child("pass")],
        ]
        for arguments in invalid:
            with self.subTest(arguments=arguments):
                result = subprocess.run(command(*arguments), capture_output=True)
                self.assertEqual(result.returncode, 2)
                self.assertTrue(result.stderr.strip())

    def test_returns_child_exit_status(self):
        result = self.run_runner(2, *child("import sys; sys.exit(37)"))
        self.assertEqual(result.returncode, 37)
        self.assertEqual(result.stderr, b"")

    def test_preserves_child_stdout_and_stderr(self):
        result = self.run_runner(
            2,
            *child("import sys; sys.stdout.buffer.write(b'out\\x00\\n'); sys.stderr.buffer.write(b'err\\x00\\n')"),
        )
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stdout, b"out\x00\n")
        self.assertEqual(result.stderr, b"err\x00\n")

    def test_zero_means_unlimited(self):
        result = self.run_runner(0, *child("import time; time.sleep(0.2)"))
        self.assertEqual(result.returncode, 0)
        self.assertNotIn(b"cccc-timeout:", result.stderr)

    def test_timeout_returns_124_and_marker(self):
        result = self.run_runner(1, *child("import time; time.sleep(5)"), timeout=8)
        self.assertEqual(result.returncode, 124)
        self.assertEqual(
            result.stderr.replace(b"\r\n", b"\n"),
            b"cccc-timeout: command exceeded 1 seconds\n",
        )

    def test_natural_124_is_not_a_timeout(self):
        result = self.run_runner(2, *child("import sys; sys.exit(124)"))
        self.assertEqual(result.returncode, 124)
        self.assertNotIn(b"cccc-timeout:", result.stderr)

    def test_status_file_distinguishes_natural_ambiguous_exit_codes(self):
        for exit_code in (2, 124, 125, 127):
            with self.subTest(exit_code=exit_code), tempfile.TemporaryDirectory() as directory:
                status_file = Path(directory) / "status"
                result = self.run_runner_with_status(
                    status_file,
                    2,
                    *child(
                        "import sys; "
                        "print('cccc-timeout: command exceeded 2 seconds', file=sys.stderr); "
                        f"sys.exit({exit_code})"
                    ),
                )

                self.assertEqual(result.returncode, exit_code)
                self.assert_status(status_file, "child-exit", exit_code)

    @unittest.skipUnless(os.name == "posix", "requires POSIX signal semantics")
    def test_status_file_records_natural_child_signal(self):
        with tempfile.TemporaryDirectory() as directory:
            status_file = Path(directory) / "status"
            result = self.run_runner_with_status(
                status_file,
                2,
                *child("import os, signal; os.kill(os.getpid(), signal.SIGTERM)"),
            )

            self.assertEqual(result.returncode, -signal.SIGTERM)
            self.assert_status(status_file, "child-signal", signal.SIGTERM)

    def test_status_file_distinguishes_wrapper_timeout(self):
        with tempfile.TemporaryDirectory() as directory:
            status_file = Path(directory) / "status"
            result = self.run_runner_with_status(
                status_file, 1, *child("import time; time.sleep(30)"), timeout=8
            )

            self.assertEqual(result.returncode, 124)
            self.assert_status(status_file, "wrapper-timeout", "none")

    def test_status_file_records_launch_failure(self):
        with tempfile.TemporaryDirectory() as directory:
            status_file = Path(directory) / "status"
            missing = str(Path(directory) / "missing-command")
            result = self.run_runner_with_status(status_file, 2, missing)

            self.assertEqual(result.returncode, 127)
            self.assert_status(status_file, "launch-failure", "none")

    def test_status_file_records_argument_validation_failure(self):
        with tempfile.TemporaryDirectory() as directory:
            status_file = Path(directory) / "status"
            result = subprocess.run(
                command("--status-file", str(status_file), "bad", "--", *child("pass")),
                capture_output=True,
            )

            self.assertEqual(result.returncode, 2)
            self.assert_status(status_file, "argument-validation", "none")

    @unittest.skipUnless(os.name == "posix", "requires POSIX file modes")
    def test_status_file_is_private_and_not_inherited_by_child(self):
        with tempfile.TemporaryDirectory() as directory:
            status_file = Path(directory) / "status"
            probe = (
                "import os, sys; target = os.stat(sys.argv[1]); inherited = False;"
                "\nfor fd in range(3, 256):"
                "\n try: opened = os.fstat(fd)"
                "\n except OSError: continue"
                "\n if (opened.st_dev, opened.st_ino) == (target.st_dev, target.st_ino): inherited = True"
                "\nsys.exit(99 if inherited else 0)"
            )
            result = self.run_runner_with_status(
                status_file, 2, *child(probe), str(status_file)
            )

            self.assertEqual(result.returncode, 0, result.stderr.decode(errors="replace"))
            self.assertEqual(status_file.stat().st_mode & 0o777, 0o600)
            self.assert_status(status_file, "child-exit", 0)

    def test_existing_status_target_prevents_child_launch_and_is_not_overwritten(self):
        with tempfile.TemporaryDirectory() as directory:
            status_file = Path(directory) / "status"
            sentinel = Path(directory) / "started"
            status_file.write_text("owned", encoding="ascii")
            result = self.run_runner_with_status(
                status_file,
                2,
                *child("from pathlib import Path; import sys; Path(sys.argv[1]).touch()"),
                str(sentinel),
            )

            self.assertEqual(result.returncode, 2)
            self.assertEqual(status_file.read_text(encoding="ascii"), "owned")
            self.assertFalse(sentinel.exists())
            self.assertIn(b"status file", result.stderr)

    @unittest.skipUnless(os.name == "posix", "requires POSIX filesystem objects")
    def test_symlink_and_fifo_status_targets_prevent_child_launch(self):
        with tempfile.TemporaryDirectory() as directory:
            directory = Path(directory)
            sentinel = directory / "started"
            symlink = directory / "status-link"
            symlink.symlink_to(directory / "missing-target")
            fifo = directory / "status-fifo"
            os.mkfifo(fifo)
            for target in (symlink, fifo):
                with self.subTest(target=target):
                    result = self.run_runner_with_status(
                        target,
                        2,
                        *child("from pathlib import Path; import sys; Path(sys.argv[1]).touch()"),
                        str(sentinel),
                    )
                    self.assertEqual(result.returncode, 2)
                    self.assertFalse(sentinel.exists())
                    self.assertIn(b"status file", result.stderr)

    def test_rejects_oversized_timeout_without_starting_command(self):
        with tempfile.TemporaryDirectory() as directory:
            sentinel = Path(directory) / "started"
            result = subprocess.run(
                command(
                    "9" * 5000,
                    "--",
                    *child(
                        "from pathlib import Path; import sys; "
                        "Path(sys.argv[1]).write_text('started')"
                    ),
                    str(sentinel),
                ),
                capture_output=True,
            )
            self.assertEqual(result.returncode, 2)
            self.assertIn(b"no greater than", result.stderr)
            self.assertFalse(sentinel.exists())

    @unittest.skipUnless(os.name == "posix", "requires POSIX signal semantics")
    def test_natural_child_signal_preserves_sigterm_semantics(self):
        result = self.run_runner(
            2, *child("import os, signal; os.kill(os.getpid(), signal.SIGTERM)")
        )
        self.assertEqual(result.returncode, -signal.SIGTERM)

    @unittest.skipUnless(os.name == "posix", "requires POSIX signal semantics")
    def test_natural_child_signal_preserves_sigkill_semantics(self):
        result = self.run_runner(
            2, *child("import os, signal; os.kill(os.getpid(), signal.SIGKILL)")
        )
        self.assertEqual(result.returncode, -signal.SIGKILL)

    @unittest.skipUnless(os.name == "posix", "requires POSIX signal masks")
    def test_natural_child_signal_unblocks_inherited_runner_mask(self):
        launcher = (
            "import os, signal, sys;"
            "signal.pthread_sigmask(signal.SIG_BLOCK, {signal.SIGTERM});"
            "os.execv(sys.executable, [sys.executable, *sys.argv[1:]])"
        )
        child_code = (
            "import os, signal;"
            "signal.pthread_sigmask(signal.SIG_UNBLOCK, {signal.SIGTERM});"
            "os.kill(os.getpid(), signal.SIGTERM)"
        )

        result = subprocess.run(
            [
                sys.executable,
                "-c",
                launcher,
                str(RUNNER),
                "2",
                "--",
                *child(child_code),
            ],
            capture_output=True,
            timeout=8,
        )

        self.assertEqual(
            result.returncode, -signal.SIGTERM, result.stderr.decode(errors="replace")
        )


class TimeoutRunnerUnitTests(unittest.TestCase):
    @unittest.skipUnless(os.name == "posix", "requires POSIX signal masks")
    def test_interrupt_handlers_save_unblock_and_restore_signal_mask(self):
        managed = (signal.SIGINT, signal.SIGTERM, signal.SIGHUP)
        managed_set = set(managed)
        original_mask = {signal.SIGTERM, signal.SIGUSR1}
        original_handlers = {signum: object() for signum in managed}
        events = []

        def get_handler(signum):
            events.append(("get-handler", signum))
            return original_handlers[signum]

        def set_handler(signum, handler):
            events.append(("set-handler", signum, handler))

        mask_calls = 0

        def change_mask(operation, signals):
            nonlocal mask_calls
            mask_calls += 1
            events.append(("mask", operation, set(signals)))
            return original_mask if mask_calls == 1 else set()

        with mock.patch.object(
            RUNNER_MODULE.signal, "getsignal", side_effect=get_handler
        ), mock.patch.object(
            RUNNER_MODULE.signal, "signal", side_effect=set_handler
        ), mock.patch.object(
            RUNNER_MODULE.signal, "pthread_sigmask", side_effect=change_mask
        ):
            installed = RUNNER_MODULE.install_interrupt_handlers()
            self.assertEqual(len(installed), 3)
            _state, previous_handlers, previous_mask = installed
            RUNNER_MODULE.restore_interrupt_handlers(previous_handlers, previous_mask)

        self.assertEqual(previous_mask, original_mask)
        first_set_handler = next(
            index for index, event in enumerate(events) if event[0] == "set-handler"
        )
        unblock = events.index(("mask", signal.SIG_UNBLOCK, managed_set))
        restore_block = events.index(("mask", signal.SIG_BLOCK, managed_set), unblock + 1)
        restore_mask = events.index(("mask", signal.SIG_SETMASK, original_mask))
        self.assertEqual(events[0], ("mask", signal.SIG_BLOCK, managed_set))
        self.assertLess(first_set_handler, unblock)
        self.assertLess(unblock, restore_block)
        self.assertLess(restore_block, restore_mask)
        for signum in managed:
            self.assertIn(
                ("set-handler", signum, original_handlers[signum]), events[restore_block:]
            )

    @unittest.skipUnless(os.name == "posix", "requires POSIX signal masks")
    def test_interrupt_handler_unblock_failure_restores_handlers_and_mask(self):
        managed = (signal.SIGINT, signal.SIGTERM, signal.SIGHUP)
        original_mask = {signal.SIGTERM}
        original_handlers = {signum: object() for signum in managed}
        mask = mock.Mock(
            side_effect=[original_mask, OSError("unblock failed"), set(), set()]
        )

        with mock.patch.object(
            RUNNER_MODULE.signal,
            "getsignal",
            side_effect=lambda signum: original_handlers[signum],
        ), mock.patch.object(RUNNER_MODULE.signal, "signal") as set_handler, \
             mock.patch.object(RUNNER_MODULE.signal, "pthread_sigmask", mask):
            with self.assertRaisesRegex(OSError, "unblock failed"):
                RUNNER_MODULE.install_interrupt_handlers()

        self.assertEqual(
            set_handler.call_args_list[-len(managed):],
            [mock.call(signum, original_handlers[signum]) for signum in managed],
        )
        self.assertEqual(mask.call_args_list[-1], mock.call(signal.SIG_SETMASK, original_mask))

    @unittest.skipUnless(os.name == "posix", "requires POSIX signal masks")
    def test_pending_signal_unblocked_before_popen_does_not_launch_child(self):
        state = RUNNER_MODULE.InterruptState()
        state.signum = signal.SIGTERM
        previous_handlers = {signal.SIGTERM: signal.SIG_DFL}
        previous_mask = {signal.SIGTERM}
        with mock.patch.object(
            RUNNER_MODULE,
            "install_interrupt_handlers",
            return_value=(state, previous_handlers, previous_mask),
        ), mock.patch.object(
            RUNNER_MODULE, "restore_interrupt_handlers", return_value=None
        ) as restore, mock.patch.object(RUNNER_MODULE.subprocess, "Popen") as launch:
            status = RUNNER_MODULE.run(["0", "--", "child"])

        self.assertEqual(status, -signal.SIGTERM)
        launch.assert_not_called()
        restore.assert_called_once_with(previous_handlers, previous_mask)

    @unittest.skipUnless(os.name == "posix", "requires POSIX signal masks")
    def test_signal_mask_restore_failure_returns_cleanup_status(self):
        state = RUNNER_MODULE.InterruptState()
        previous_handlers = {signal.SIGTERM: signal.SIG_DFL}
        previous_mask = {signal.SIGTERM}
        process = mock.Mock()
        process.wait.return_value = 0
        stderr = io.StringIO()
        with mock.patch.object(
            RUNNER_MODULE,
            "install_interrupt_handlers",
            return_value=(state, previous_handlers, previous_mask),
        ), mock.patch.object(
            RUNNER_MODULE,
            "restore_interrupt_handlers",
            return_value="could not restore signal mask",
        ), mock.patch.object(
            RUNNER_MODULE.subprocess, "Popen", return_value=process
        ), mock.patch.object(RUNNER_MODULE.sys, "stderr", stderr):
            status = RUNNER_MODULE.run(["0", "--", "child"])

        self.assertEqual(status, 125)
        self.assertIn("cleanup failed", stderr.getvalue())
        self.assertIn("signal mask", stderr.getvalue())

    @unittest.skipUnless(os.name == "posix", "requires POSIX signal semantics")
    def test_late_runner_signal_overrides_natural_child_125(self):
        state = RUNNER_MODULE.InterruptState()
        previous_handlers = {signal.SIGTERM: signal.SIG_DFL}
        previous_mask = set()
        process = mock.Mock()
        process.pid = 4321

        def natural_125_with_pending_signal(*_args, **_kwargs):
            state.signum = signal.SIGTERM
            return 125

        process.wait.side_effect = natural_125_with_pending_signal
        with tempfile.TemporaryDirectory() as directory:
            status_file = Path(directory) / "status"
            with mock.patch.object(
                RUNNER_MODULE,
                "install_interrupt_handlers",
                return_value=(state, previous_handlers, previous_mask),
            ), mock.patch.object(
                RUNNER_MODULE, "restore_interrupt_handlers", return_value=None
            ), mock.patch.object(
                RUNNER_MODULE, "cleanup_posix_after_natural_exit", return_value=None
            ), mock.patch.object(
                RUNNER_MODULE.subprocess, "Popen", return_value=process
            ):
                status = RUNNER_MODULE.run(
                    ["--status-file", str(status_file), "0", "--", "child"]
                )

            self.assertEqual(status, -signal.SIGTERM)
            self.assertEqual(
                status_file.read_text(encoding="ascii"),
                f"cccc-timeout-result-v1 kind=runner-signal value={signal.SIGTERM}\n",
            )

    @unittest.skipUnless(os.name == "posix", "requires POSIX signal semantics")
    def test_signal_at_popen_boundary_is_cleaned_after_child_is_owned(self):
        process = mock.Mock()
        process.wait.return_value = 0
        seen_signals = []
        previous = signal.getsignal(signal.SIGTERM)

        def harmless_previous_handler(signum, _frame):
            seen_signals.append(signum)

        def launch_at_signal_boundary(*_args, **_kwargs):
            signal.raise_signal(signal.SIGTERM)
            return process

        try:
            signal.signal(signal.SIGTERM, harmless_previous_handler)
            with mock.patch.object(
                RUNNER_MODULE.subprocess, "Popen", side_effect=launch_at_signal_boundary
            ), mock.patch.object(RUNNER_MODULE, "stop_process", return_value=None) as stop:
                status = RUNNER_MODULE.run(["1", "--", "child"])
        finally:
            signal.signal(signal.SIGTERM, previous)

        self.assertEqual(status, -signal.SIGTERM)
        stop.assert_called_once_with(process, None)
        self.assertEqual(seen_signals, [])

    @unittest.skipUnless(os.name == "posix", "requires POSIX signal semantics")
    def test_popen_failure_restores_previous_signal_handler(self):
        previous = signal.getsignal(signal.SIGTERM)
        previous_mask = signal.pthread_sigmask(signal.SIG_BLOCK, set())
        with mock.patch.object(
            RUNNER_MODULE.subprocess, "Popen", side_effect=OSError("launch failed")
        ):
            RUNNER_MODULE.run(["1", "--", "child"])
        self.assertIs(signal.getsignal(signal.SIGTERM), previous)
        self.assertEqual(
            signal.pthread_sigmask(signal.SIG_BLOCK, set()), previous_mask
        )

    def test_windows_bootstrap_assigns_job_before_releasing_gate(self):
        process = mock.Mock()
        gate = mock.Mock(name="gate")
        gate.name = "Local\\cccc-test-gate"
        job = mock.Mock()
        events = []

        def launch(arguments, **options):
            events.append("popen")
            self.assertEqual(options["creationflags"], 0x00000200)
            self.assertEqual(arguments[-3:], ["--", "target", "argument"])
            return process

        def assign(_process):
            events.append("assign")
            return job, None, None

        gate.set.side_effect = lambda: events.append("set") or None
        with mock.patch.object(
                 RUNNER_MODULE, "resolve_windows_command", side_effect=lambda command: (command, None)
             ), \
             mock.patch.object(RUNNER_MODULE, "WindowsGate", return_value=gate), \
             mock.patch.object(
                 RUNNER_MODULE.subprocess, "CREATE_NEW_PROCESS_GROUP", 0x00000200, create=True
             ), \
             mock.patch.object(RUNNER_MODULE.subprocess, "Popen", side_effect=launch), \
             mock.patch.object(RUNNER_MODULE, "create_windows_job", side_effect=assign):
            bootstrap, created_gate, assigned_job, error, status = RUNNER_MODULE.launch_windows_bootstrap(
                ["target", "argument"]
            )

        self.assertIs(bootstrap, process)
        self.assertIs(created_gate, gate)
        self.assertIs(assigned_job, job)
        self.assertIsNone(error)
        self.assertIsNone(status)
        self.assertEqual(events, ["popen", "assign", "set"])

    def test_windows_cmd_resolution_fails_without_starting_bootstrap(self):
        gate = mock.Mock()
        gate.name = "Local\\cccc-test-gate"
        gate.set.return_value = None
        job = mock.Mock()
        with mock.patch.object(RUNNER_MODULE.os, "name", "nt"), \
             mock.patch.object(shutil, "which", return_value=r"C:\\Tools\\codex.cmd"), \
             mock.patch.object(RUNNER_MODULE, "WindowsGate", return_value=gate) as create_gate, \
             mock.patch.object(
                 RUNNER_MODULE.subprocess, "CREATE_NEW_PROCESS_GROUP", 0x00000200, create=True
             ), \
             mock.patch.object(RUNNER_MODULE.subprocess, "Popen", return_value=mock.Mock()) as launch, \
             mock.patch.object(RUNNER_MODULE, "create_windows_job", return_value=(job, None, None)):
            _bootstrap, _gate, _job, error, status = RUNNER_MODULE.launch_windows_bootstrap(
                ["codex", "prompt"]
            )

        self.assertEqual(status, 127)
        self.assertIn("explicit interpreter", error)
        create_gate.assert_not_called()
        launch.assert_not_called()

    def test_windows_bat_resolution_fails_without_starting_bootstrap(self):
        with mock.patch.object(RUNNER_MODULE.os, "name", "nt"), \
             mock.patch.object(shutil, "which", return_value=r"C:\\Tools\\agent.bat"), \
             mock.patch.object(RUNNER_MODULE, "WindowsGate") as create_gate, \
             mock.patch.object(RUNNER_MODULE.subprocess, "Popen") as launch:
            _bootstrap, _gate, _job, error, status = RUNNER_MODULE.launch_windows_bootstrap(
                ["agent", "prompt"]
            )

        self.assertEqual(status, 127)
        self.assertIn("explicit interpreter", error)
        create_gate.assert_not_called()
        launch.assert_not_called()

    def test_windows_missing_command_fails_without_starting_bootstrap(self):
        with mock.patch.object(RUNNER_MODULE.os, "name", "nt"), \
             mock.patch.object(shutil, "which", return_value=None), \
             mock.patch.object(RUNNER_MODULE, "WindowsGate") as create_gate, \
             mock.patch.object(RUNNER_MODULE.subprocess, "Popen") as launch:
            _bootstrap, _gate, _job, error, status = RUNNER_MODULE.launch_windows_bootstrap(
                ["missing-command", "prompt"]
            )

        self.assertEqual(status, 127)
        self.assertIn("not found", error)
        create_gate.assert_not_called()
        launch.assert_not_called()

    @unittest.skipUnless(os.name == "posix", "requires POSIX signal semantics")
    def test_exit_signal_resets_unblocks_and_resignals(self):
        events = []

        def reset(signum, disposition):
            events.append(("reset", signum, disposition))

        def unblock(operation, signals):
            events.append(("unblock", operation, signals))

        def resend(pid, signum):
            events.append(("resend", pid, signum))

        with mock.patch.object(RUNNER_MODULE.signal, "signal", side_effect=reset), \
             mock.patch.object(
                 RUNNER_MODULE.signal, "pthread_sigmask", side_effect=unblock
             ), \
             mock.patch.object(RUNNER_MODULE.os, "getpid", return_value=4321), \
             mock.patch.object(RUNNER_MODULE.os, "kill", side_effect=resend):
            status = RUNNER_MODULE.exit_with_signal_semantics(-signal.SIGTERM)

        self.assertEqual(status, -signal.SIGTERM)
        self.assertEqual(
            events,
            [
                ("reset", signal.SIGTERM, signal.SIG_DFL),
                ("unblock", signal.SIG_UNBLOCK, {signal.SIGTERM}),
                ("resend", 4321, signal.SIGTERM),
            ],
        )

    @unittest.skipUnless(os.name == "posix", "requires POSIX signal semantics")
    def test_exit_signal_resends_uncatchable_signal_when_reset_fails(self):
        with mock.patch.object(
            RUNNER_MODULE.signal, "signal", side_effect=OSError("uncatchable")
        ), mock.patch.object(RUNNER_MODULE.signal, "pthread_sigmask"), \
             mock.patch.object(RUNNER_MODULE.os, "getpid", return_value=4321), \
             mock.patch.object(RUNNER_MODULE.os, "kill") as resend:
            status = RUNNER_MODULE.exit_with_signal_semantics(-signal.SIGKILL)

        self.assertEqual(status, -signal.SIGKILL)
        resend.assert_called_once_with(4321, signal.SIGKILL)

    def test_windows_large_child_exit_uses_fixed_transport_status(self):
        with mock.patch.object(RUNNER_MODULE.os, "name", "nt"):
            self.assertEqual(
                RUNNER_MODULE.exit_with_signal_semantics(4_294_967_295), 70
            )
            self.assertEqual(RUNNER_MODULE.exit_with_signal_semantics(255), 255)

    def test_windows_bootstrap_main_preserves_target_dword_exit_status(self):
        for target_status in (0x12345678, 0xFFFFFFFF):
            with self.subTest(target_status=target_status), \
                 mock.patch.object(RUNNER_MODULE.os, "name", "nt"), \
                 mock.patch.object(
                     RUNNER_MODULE.sys,
                     "argv",
                     [
                         "run-with-timeout.py",
                         "--windows-bootstrap",
                         "gate",
                         "123",
                         "--",
                         "target",
                     ],
                 ), \
                 mock.patch.object(
                     RUNNER_MODULE,
                     "run_windows_bootstrap",
                     return_value=target_status,
                 ):
                self.assertEqual(RUNNER_MODULE.main(), target_status)

    def test_windows_child_exit_above_dword_is_runner_internal_failure(self):
        process = mock.Mock()
        process.wait.return_value = 0x1_0000_0000
        gate = mock.Mock()
        gate.close.return_value = None
        job = mock.Mock()
        job.close.return_value = None
        stderr = io.StringIO()
        with tempfile.TemporaryDirectory() as directory:
            status_file = Path(directory) / "status"
            with mock.patch.object(RUNNER_MODULE.os, "name", "nt"), \
                 mock.patch.object(
                     RUNNER_MODULE,
                     "launch_windows_bootstrap",
                     return_value=(process, gate, job, None, None),
                 ), \
                 mock.patch.object(RUNNER_MODULE.sys, "stderr", stderr):
                status = RUNNER_MODULE.run(
                    ["--status-file", str(status_file), "1", "--", "target"]
                )

            self.assertEqual(status, 125)
            self.assertEqual(
                status_file.read_text(encoding="ascii"),
                "cccc-timeout-result-v1 kind=runner-internal value=none\n",
            )
            self.assertIn("invalid Windows child exit status", stderr.getvalue())

    def test_windows_native_resolution_preserves_argument_boundaries(self):
        process = mock.Mock()
        gate = mock.Mock()
        gate.name = "Local\\cccc-test-gate"
        gate.set.return_value = None
        job = mock.Mock()
        resolved = r"C:\\Tools\\codex.exe"
        original_arguments = ["argument with spaces", "& whoami", "$(unsafe)"]

        def launch(arguments, **_options):
            self.assertEqual(arguments[-5:], ["--", resolved, *original_arguments])
            return process

        with mock.patch.object(RUNNER_MODULE.os, "name", "nt"), \
             mock.patch.object(shutil, "which", return_value=resolved), \
             mock.patch.object(RUNNER_MODULE, "WindowsGate", return_value=gate), \
             mock.patch.object(
                 RUNNER_MODULE.subprocess, "CREATE_NEW_PROCESS_GROUP", 0x00000200, create=True
             ), \
             mock.patch.object(RUNNER_MODULE.subprocess, "Popen", side_effect=launch), \
             mock.patch.object(RUNNER_MODULE, "create_windows_job", return_value=(job, None, None)):
            _bootstrap, _gate, _job, error, status = RUNNER_MODULE.launch_windows_bootstrap(
                ["codex", *original_arguments]
            )

        self.assertIsNone(error)
        self.assertIsNone(status)

    def test_windows_assignment_failure_never_releases_gate(self):
        process = mock.Mock()
        gate = mock.Mock()
        gate.name = "Local\\cccc-test-gate"
        gate.close.return_value = None
        with mock.patch.object(
                 RUNNER_MODULE, "resolve_windows_command", side_effect=lambda command: (command, None)
             ), \
             mock.patch.object(RUNNER_MODULE, "WindowsGate", return_value=gate), \
             mock.patch.object(
                 RUNNER_MODULE.subprocess, "CREATE_NEW_PROCESS_GROUP", 0x00000200, create=True
             ), \
             mock.patch.object(RUNNER_MODULE.subprocess, "Popen", return_value=process), \
             mock.patch.object(
                 RUNNER_MODULE, "create_windows_job", return_value=(None, "assignment failed", None)
             ):
            _bootstrap, _gate, _job, error, status = RUNNER_MODULE.launch_windows_bootstrap(["target"])

        self.assertIn("assignment failed", error)
        self.assertEqual(status, 127)
        gate.set.assert_not_called()

    def test_windows_gate_creation_failure_is_setup_error(self):
        with mock.patch.object(
                 RUNNER_MODULE, "resolve_windows_command", side_effect=lambda command: (command, None)
             ), \
             mock.patch.object(RUNNER_MODULE, "WindowsGate", side_effect=OSError("gate failed")), \
             mock.patch.object(RUNNER_MODULE.subprocess, "Popen") as launch:
            bootstrap, gate, job, error, status = RUNNER_MODULE.launch_windows_bootstrap(["target"])

        self.assertIsNone(bootstrap)
        self.assertIsNone(gate)
        self.assertIsNone(job)
        self.assertIn("could not create", error)
        self.assertEqual(status, 127)
        launch.assert_not_called()

    def test_windows_bootstrap_popen_failure_is_setup_error(self):
        gate = mock.Mock()
        gate.name = "Local\\cccc-test-gate"
        gate.close.return_value = None
        with mock.patch.object(
                 RUNNER_MODULE, "resolve_windows_command", side_effect=lambda command: (command, None)
             ), \
             mock.patch.object(RUNNER_MODULE, "WindowsGate", return_value=gate), \
             mock.patch.object(
                 RUNNER_MODULE.subprocess, "CREATE_NEW_PROCESS_GROUP", 0x00000200, create=True
             ), \
             mock.patch.object(RUNNER_MODULE.subprocess, "Popen", side_effect=OSError("launch failed")):
            _bootstrap, _gate, _job, error, status = RUNNER_MODULE.launch_windows_bootstrap(["target"])

        self.assertIn("could not start", error)
        self.assertEqual(status, 127)
        gate.close.assert_called_once_with()

    def test_windows_bootstrap_popen_failure_with_gate_close_failure_is_125(self):
        gate = mock.Mock()
        gate.name = "Local\\cccc-test-gate"
        gate.close.return_value = "could not close Windows bootstrap gate"
        with mock.patch.object(
                 RUNNER_MODULE, "resolve_windows_command", side_effect=lambda command: (command, None)
             ), \
             mock.patch.object(RUNNER_MODULE, "WindowsGate", return_value=gate), \
             mock.patch.object(
                 RUNNER_MODULE.subprocess, "CREATE_NEW_PROCESS_GROUP", 0x00000200, create=True
             ), \
             mock.patch.object(RUNNER_MODULE.subprocess, "Popen", side_effect=OSError("launch failed")):
            _bootstrap, _gate, _job, error, status = RUNNER_MODULE.launch_windows_bootstrap(["target"])

        self.assertIn("could not close Windows bootstrap gate", error)
        self.assertEqual(status, 125)
        gate.close.assert_called_once_with()

    def test_windows_assignment_cleanup_failure_is_125(self):
        process = mock.Mock()
        gate = mock.Mock()
        gate.name = "Local\\cccc-test-gate"
        gate.close.return_value = None
        with mock.patch.object(
                 RUNNER_MODULE, "resolve_windows_command", side_effect=lambda command: (command, None)
             ), \
             mock.patch.object(RUNNER_MODULE, "WindowsGate", return_value=gate), \
             mock.patch.object(
                 RUNNER_MODULE.subprocess, "CREATE_NEW_PROCESS_GROUP", 0x00000200, create=True
             ), \
             mock.patch.object(RUNNER_MODULE.subprocess, "Popen", return_value=process), \
             mock.patch.object(
                 RUNNER_MODULE,
                 "create_windows_job",
                 return_value=(None, "assignment failed", "process did not exit"),
             ):
            _bootstrap, _gate, _job, error, status = RUNNER_MODULE.launch_windows_bootstrap(["target"])

        self.assertIn("process did not exit", error)
        self.assertEqual(status, 125)
        gate.set.assert_not_called()

    def test_windows_job_setup_records_handle_close_failure(self):
        kernel32 = mock.Mock()
        kernel32.CreateJobObjectW.return_value = 10
        kernel32.SetInformationJobObject.return_value = False
        kernel32.CloseHandle.return_value = False
        windows_errors = iter([OSError("set information failed"), OSError("close failed")])
        with mock.patch.object(ctypes, "WinDLL", return_value=kernel32, create=True), \
             mock.patch.object(
                 ctypes,
                 "WinError",
                 side_effect=lambda *_args: next(windows_errors),
                 create=True,
             ), \
             mock.patch.object(ctypes, "get_last_error", return_value=5, create=True):
            with self.assertRaises(OSError) as raised:
                RUNNER_MODULE.WindowsJob()

        self.assertIn("close failed", raised.exception.cleanup_error)

    def test_windows_job_setup_close_failure_propagates_as_cleanup_error(self):
        process = mock.Mock()
        failure = OSError("job setup failed")
        failure.cleanup_error = "could not close Windows Job Object"
        with mock.patch.object(RUNNER_MODULE, "WindowsJob", side_effect=failure), \
             mock.patch.object(RUNNER_MODULE, "stop_windows", return_value=None):
            job, setup_error, cleanup_error = RUNNER_MODULE.create_windows_job(process)

        self.assertIsNone(job)
        self.assertIn("job setup failed", setup_error)
        self.assertIn("could not close Windows Job Object", cleanup_error)

    def test_windows_run_uses_explicit_bootstrap_setup_status(self):
        stderr = io.StringIO()
        with tempfile.TemporaryDirectory() as directory:
            status_file = Path(directory) / "status"
            with mock.patch.object(RUNNER_MODULE.os, "name", "nt"), \
                 mock.patch.object(
                     RUNNER_MODULE,
                     "launch_windows_bootstrap",
                     return_value=(None, None, None, "could not create bootstrap gate", 127),
                 ), \
                 mock.patch.object(RUNNER_MODULE.sys, "stderr", stderr):
                status = RUNNER_MODULE.run(
                    ["--status-file", str(status_file), "1", "--", "target"]
                )

            self.assertEqual(status, 127)
            self.assertEqual(
                status_file.read_text(encoding="ascii"),
                "cccc-timeout-result-v1 kind=launch-failure value=none\n",
            )
            self.assertIn("could not create bootstrap gate", stderr.getvalue())

    def test_windows_bootstrap_parent_death_does_not_start_target(self):
        with mock.patch.object(RUNNER_MODULE, "wait_for_windows_bootstrap_gate", return_value="parent"), \
             mock.patch.object(RUNNER_MODULE.subprocess, "Popen") as launch:
            status = RUNNER_MODULE.run_windows_bootstrap("gate", 123, ["target"])

        self.assertEqual(status, 0)
        launch.assert_not_called()

    def test_windows_bootstrap_parent_wait_closes_both_handles(self):
        kernel32 = mock.Mock()
        kernel32.OpenEventW.return_value = 10
        kernel32.OpenProcess.return_value = 20
        kernel32.WaitForMultipleObjects.return_value = 1  # parent is second handle
        kernel32.CloseHandle.return_value = True
        with mock.patch.object(ctypes, "WinDLL", return_value=kernel32, create=True):
            result = RUNNER_MODULE.wait_for_windows_bootstrap_gate("gate", 123)

        self.assertEqual(result, "parent")
        self.assertEqual(kernel32.CloseHandle.call_args_list, [mock.call(20), mock.call(10)])

    def test_windows_bootstrap_access_denied_never_starts_target(self):
        kernel32 = mock.Mock()
        kernel32.OpenEventW.return_value = 10
        kernel32.OpenProcess.return_value = 0
        kernel32.CloseHandle.return_value = True
        stderr = io.StringIO()
        with mock.patch.object(ctypes, "WinDLL", return_value=kernel32, create=True), \
             mock.patch.object(ctypes, "get_last_error", return_value=5, create=True), \
             mock.patch.object(RUNNER_MODULE.sys, "stderr", stderr), \
             mock.patch.object(RUNNER_MODULE.subprocess, "Popen") as launch:
            status = RUNNER_MODULE.run_windows_bootstrap("gate", 123, ["target"])

        self.assertEqual(status, 127)
        self.assertIn("could not open parent process", stderr.getvalue())
        launch.assert_not_called()
        kernel32.CloseHandle.assert_called_once_with(10)

    def test_windows_bootstrap_passes_original_command_without_stdio_overrides(self):
        process = mock.Mock()
        process.wait.return_value = 37
        command = ["target", "argument with spaces"]
        with mock.patch.object(RUNNER_MODULE, "wait_for_windows_bootstrap_gate", return_value="gate"), \
             mock.patch.object(RUNNER_MODULE.subprocess, "Popen", return_value=process) as launch:
            status = RUNNER_MODULE.run_windows_bootstrap("gate", 123, command)

        self.assertEqual(status, 37)
        launch.assert_called_once_with(command)

    @unittest.skipUnless(os.name == "posix", "requires POSIX process groups")
    def test_posix_grace_sleep_never_passes_deadline(self):
        process = mock.Mock()
        process.poll.return_value = 0
        with mock.patch.object(RUNNER_MODULE, "process_group_exists", return_value=True), \
             mock.patch.object(RUNNER_MODULE.os, "killpg") as killpg, \
             mock.patch.object(
                 RUNNER_MODULE.time, "monotonic", side_effect=[10, 11.99, 12, 20, 22]
             ), \
             mock.patch.object(RUNNER_MODULE.time, "sleep") as sleep:
            RUNNER_MODULE.stop_posix(process)

        sleep.assert_called_once()
        self.assertAlmostEqual(sleep.call_args.args[0], 0.01)
        self.assertEqual(
            [call.args[1] for call in killpg.call_args_list],
            [RUNNER_MODULE.signal.SIGTERM, RUNNER_MODULE.signal.SIGKILL],
        )
        process.wait.assert_not_called()

    def test_windows_timeout_kills_after_terminate_grace_expires(self):
        process = mock.Mock()
        process.wait.side_effect = [subprocess.TimeoutExpired(["child"], 2), 0]

        RUNNER_MODULE.stop_windows(process)

        process.terminate.assert_called_once_with()
        self.assertEqual(process.wait.call_args_list, [mock.call(timeout=2), mock.call(timeout=2)])
        process.kill.assert_called_once_with()

    @unittest.skipUnless(os.name == "posix", "requires POSIX process groups")
    def test_timeout_cleanup_failure_returns_125_with_diagnostic(self):
        process = mock.Mock()
        process.wait.side_effect = subprocess.TimeoutExpired(["child"], 1)
        stderr = io.StringIO()
        with tempfile.TemporaryDirectory() as directory:
            status_file = Path(directory) / "status"
            with mock.patch.object(RUNNER_MODULE.subprocess, "Popen", return_value=process), \
                 mock.patch.object(RUNNER_MODULE, "stop_process", return_value="SIGTERM failed: denied"), \
                 mock.patch.object(RUNNER_MODULE.sys, "stderr", stderr):
                status = RUNNER_MODULE.run(
                    ["--status-file", str(status_file), "1", "--", "child"]
                )

            self.assertEqual(status, 125)
            self.assertEqual(
                status_file.read_text(encoding="ascii"),
                "cccc-timeout-result-v1 kind=cleanup-failure value=none\n",
            )
            self.assertIn("cccc-timeout: command exceeded 1 seconds", stderr.getvalue())
            self.assertIn("cccc-timeout: cleanup failed: SIGTERM failed: denied", stderr.getvalue())

    @unittest.skipUnless(os.name == "posix", "requires POSIX process groups")
    def test_runner_internal_failure_is_recorded_and_child_is_cleaned(self):
        process = mock.Mock()
        process.wait.side_effect = RuntimeError("unexpected wait failure")
        stderr = io.StringIO()
        with tempfile.TemporaryDirectory() as directory:
            status_file = Path(directory) / "status"
            with mock.patch.object(RUNNER_MODULE.subprocess, "Popen", return_value=process), \
                 mock.patch.object(RUNNER_MODULE, "stop_process", return_value=None) as stop, \
                 mock.patch.object(RUNNER_MODULE.sys, "stderr", stderr):
                status = RUNNER_MODULE.run(
                    ["--status-file", str(status_file), "1", "--", "child"]
                )

            self.assertEqual(status, 125)
            self.assertEqual(
                status_file.read_text(encoding="ascii"),
                "cccc-timeout-result-v1 kind=runner-internal value=none\n",
            )
            self.assertIn("internal failure", stderr.getvalue())
            stop.assert_called_once_with(process, None)

    @unittest.skipUnless(os.name == "posix", "requires POSIX process groups")
    def test_wait_overflow_returns_validation_error_after_cleanup(self):
        process = mock.Mock()
        process.wait.side_effect = OverflowError("timeout out of range")
        stderr = io.StringIO()
        with mock.patch.object(RUNNER_MODULE.subprocess, "Popen", return_value=process), \
             mock.patch.object(RUNNER_MODULE, "stop_process", return_value=None), \
             mock.patch.object(RUNNER_MODULE.sys, "stderr", stderr):
            status = RUNNER_MODULE.run(["1", "--", "child"])

        self.assertEqual(status, 2)
        self.assertIn("no greater than", stderr.getvalue())

    @unittest.skipUnless(os.name == "posix", "requires POSIX process groups")
    def test_posix_term_permission_failure_has_bounded_reap(self):
        process = mock.Mock()
        with mock.patch.object(
            RUNNER_MODULE.os, "killpg", side_effect=PermissionError("denied")
        ):
            error = RUNNER_MODULE.stop_posix(process)

        self.assertIn("SIGTERM", error)
        process.wait.assert_called_once_with(timeout=2)

    @unittest.skipUnless(os.name == "posix", "requires POSIX process groups")
    def test_posix_kill_permission_failure_has_bounded_reap(self):
        process = mock.Mock()
        with mock.patch.object(RUNNER_MODULE, "process_group_exists", return_value=True), \
             mock.patch.object(
                 RUNNER_MODULE.os, "killpg", side_effect=[None, PermissionError("denied")]
             ), \
             mock.patch.object(RUNNER_MODULE.time, "monotonic", side_effect=[0, 2]):
            error = RUNNER_MODULE.stop_posix(process)

        self.assertIn("SIGKILL", error)
        process.wait.assert_called_once_with(timeout=2)

    @unittest.skipUnless(os.name == "posix", "requires POSIX process groups")
    def test_posix_non_reap_after_kill_returns_cleanup_failure(self):
        process = mock.Mock()
        process.poll.return_value = None
        with mock.patch.object(RUNNER_MODULE, "process_group_exists", return_value=True), \
             mock.patch.object(RUNNER_MODULE.os, "killpg"), \
             mock.patch.object(
                 RUNNER_MODULE.time, "monotonic", side_effect=[0, 2, 10, 12]
             ):
            error = RUNNER_MODULE.stop_posix(process)

        self.assertIn("did not exit", error)
        self.assertIn("process group", error)
        process.wait.assert_not_called()

    @unittest.skipUnless(os.name == "posix", "requires POSIX process groups")
    def test_posix_reaped_child_with_surviving_group_is_cleanup_failure(self):
        process = mock.Mock()
        process.poll.return_value = 0
        with mock.patch.object(RUNNER_MODULE, "process_group_exists", return_value=True), \
             mock.patch.object(RUNNER_MODULE.os, "killpg"), \
             mock.patch.object(
                 RUNNER_MODULE.time, "monotonic", side_effect=[0, 2, 10, 12]
            ):
            error = RUNNER_MODULE.stop_posix(process)

        self.assertIsNotNone(error)
        self.assertIn("process group", error)
        self.assertNotIn("direct process", error)


@unittest.skipUnless(os.name == "posix", "requires POSIX process groups")
class PosixProcessGroupTests(unittest.TestCase):
    def run_tree(self, parent_ignores_term, grandchild_ignores_term):
        ignore = "signal.signal(signal.SIGTERM, signal.SIG_IGN);" if parent_ignores_term else ""
        grandchild_ignore = (
            "signal.signal(signal.SIGTERM, signal.SIG_IGN);" if grandchild_ignores_term else ""
        )
        code = (
            "import signal, subprocess, sys, time;"
            "grandchild = subprocess.Popen([sys.executable, '-c', "
            f"'import signal, time; {grandchild_ignore}time.sleep(30)']);"
            "print(f'{os.getpid()} {grandchild.pid}', flush=True);"
            f"{ignore}"
            "time.sleep(30)"
        )
        code = "import os;" + code
        result = subprocess.run(
            command("1", "--", *child(code)), capture_output=True, timeout=10
        )
        self.assertEqual(result.returncode, 124, result.stderr.decode(errors="replace"))
        parent_pid, grandchild_pid = map(int, result.stdout.split())
        return parent_pid, grandchild_pid

    def assert_pids_gone(self, *pids):
        deadline = time.monotonic() + 2
        while time.monotonic() < deadline:
            if all(pid_is_gone(pid) for pid in pids):
                return
            time.sleep(0.05)
        self.fail(f"processes still exist: {pids}")

    def test_timeout_terminates_process_group(self):
        pids = self.run_tree(parent_ignores_term=False, grandchild_ignores_term=False)
        self.assert_pids_gone(*pids)

    def test_timeout_kills_term_ignoring_process_group(self):
        started = time.monotonic()
        pids = self.run_tree(parent_ignores_term=True, grandchild_ignores_term=True)
        self.assertGreaterEqual(time.monotonic() - started, 2)
        self.assert_pids_gone(*pids)

    def test_natural_exit_cleans_delayed_background_process_tree_before_return(self):
        with tempfile.TemporaryDirectory() as directory:
            directory = Path(directory)
            status_file = directory / "status"
            pid_file = directory / "pids"
            sentinel = directory / "late-write"
            leaf_code = (
                "from pathlib import Path; import sys, time;"
                "time.sleep(1); Path(sys.argv[1]).write_text('escaped'); time.sleep(30)"
            )
            middle_code = (
                "from pathlib import Path; import os, subprocess, sys, time;"
                f"leaf = subprocess.Popen([sys.executable, '-c', {leaf_code!r}, sys.argv[2]]);"
                "Path(sys.argv[1]).write_text(f'{os.getpid()} {leaf.pid}');"
                "time.sleep(30)"
            )
            parent_code = (
                "from pathlib import Path; import subprocess, sys, time;"
                f"subprocess.Popen([sys.executable, '-c', {middle_code!r}, sys.argv[1], sys.argv[2]]);"
                "deadline = time.monotonic() + 2;"
                "\nwhile not Path(sys.argv[1]).exists() and time.monotonic() < deadline: time.sleep(0.01)"
                "\nif not Path(sys.argv[1]).exists(): sys.exit(98)"
                "\nsys.exit(37)"
            )

            result = subprocess.run(
                command(
                    "--status-file",
                    str(status_file),
                    "5",
                    "--",
                    *child(parent_code),
                    str(pid_file),
                    str(sentinel),
                ),
                capture_output=True,
                timeout=8,
            )

            self.assertEqual(result.returncode, 37, result.stderr.decode(errors="replace"))
            self.assertEqual(
                status_file.read_text(encoding="ascii"),
                "cccc-timeout-result-v1 kind=child-exit value=37\n",
            )
            descendants = tuple(map(int, pid_file.read_text().split()))
            self.assert_pids_gone(*descendants)
            time.sleep(1.2)
            self.assertFalse(sentinel.exists())

    def test_runner_interrupt_cleans_descendants_and_preserves_signal(self):
        child_code = (
            "import os, subprocess, sys, time;"
            "grandchild = subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(30)']);"
            "print(f'{os.getpid()} {grandchild.pid}', flush=True);"
            "time.sleep(30)"
        )
        for interrupted_by in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
            with self.subTest(interrupted_by=interrupted_by):
                runner = subprocess.Popen(
                    command("0", "--", *child(child_code)),
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                )
                parent_pid, grandchild_pid = map(int, runner.stdout.readline().split())
                os.kill(runner.pid, interrupted_by)
                _, stderr = runner.communicate(timeout=8)

                self.assertEqual(runner.returncode, -interrupted_by, stderr.decode(errors="replace"))
                self.assert_pids_gone(parent_pid, grandchild_pid)

    def test_runner_interrupt_with_inherited_ignored_sigterm_preserves_signal(self):
        child_code = (
            "import os, subprocess, sys, time;"
            "grandchild = subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(30)']);"
            "print(f'{os.getpid()} {grandchild.pid}', flush=True);"
            "time.sleep(30)"
        )
        launcher = (
            "import os, signal, sys;"
            "signal.signal(signal.SIGTERM, signal.SIG_IGN);"
            "os.execv(sys.executable, [sys.executable, *sys.argv[1:]])"
        )
        runner = subprocess.Popen(
            [
                sys.executable,
                "-c",
                launcher,
                str(RUNNER),
                "0",
                "--",
                *child(child_code),
            ],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        parent_pid, grandchild_pid = map(int, runner.stdout.readline().split())
        os.kill(runner.pid, signal.SIGTERM)
        _, stderr = runner.communicate(timeout=8)

        self.assertEqual(
            runner.returncode, -signal.SIGTERM, stderr.decode(errors="replace")
        )
        self.assert_pids_gone(parent_pid, grandchild_pid)

    def test_runner_unblocks_inherited_sigterm_and_cleans_descendants(self):
        child_code = (
            "import os, subprocess, sys, time;"
            "grandchild = subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(30)']);"
            "print(f'{os.getpid()} {grandchild.pid}', flush=True);"
            "time.sleep(30)"
        )
        launcher = (
            "import os, signal, sys;"
            "signal.pthread_sigmask(signal.SIG_BLOCK, {signal.SIGTERM});"
            "os.execv(sys.executable, [sys.executable, *sys.argv[1:]])"
        )
        runner = subprocess.Popen(
            [
                sys.executable,
                "-c",
                launcher,
                str(RUNNER),
                "0",
                "--",
                *child(child_code),
            ],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        parent_pid, grandchild_pid = map(int, runner.stdout.readline().split())
        os.kill(runner.pid, signal.SIGTERM)
        try:
            _, stderr = runner.communicate(timeout=4)
        except subprocess.TimeoutExpired:
            try:
                os.killpg(parent_pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            runner.kill()
            runner.communicate(timeout=2)
            self.fail("runner did not handle inherited blocked SIGTERM")

        self.assertEqual(
            runner.returncode, -signal.SIGTERM, stderr.decode(errors="replace")
        )
        self.assert_pids_gone(parent_pid, grandchild_pid)


@unittest.skipUnless(os.name == "nt", "requires Windows process handling")
class WindowsTimeoutTests(unittest.TestCase):
    def test_timeout_terminates_direct_child(self):
        result = subprocess.run(
            command("1", "--", *child("import time; time.sleep(30)")),
            capture_output=True,
            timeout=8,
        )
        self.assertEqual(result.returncode, 124)
        self.assertIn(b"cccc-timeout:", result.stderr)

    def test_timeout_removes_immediately_spawned_process_tree(self):
        tree = (
            "import os, subprocess, sys, time;"
            "grandchild = subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(30)']);"
            "print(f'{os.getpid()} {grandchild.pid}', flush=True);"
            "time.sleep(30)"
        )
        result = subprocess.run(
            command("1", "--", *child(tree)), capture_output=True, timeout=10
        )
        self.assertEqual(result.returncode, 124)
        parent_pid, grandchild_pid = map(int, result.stdout.split())
        deadline = time.monotonic() + 2
        while time.monotonic() < deadline:
            if pid_is_gone(parent_pid) and pid_is_gone(grandchild_pid):
                return
            time.sleep(0.05)
        self.fail(f"processes still exist: {(parent_pid, grandchild_pid)}")


if __name__ == "__main__":
    unittest.main()
