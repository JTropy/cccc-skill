"""Integration tests for the portable timeout runner."""

import os
from pathlib import Path
import signal
import io
import ctypes
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
        self.assertEqual(result.stderr, b"cccc-timeout: command exceeded 1 seconds\n")

    def test_natural_124_is_not_a_timeout(self):
        result = self.run_runner(2, *child("import sys; sys.exit(124)"))
        self.assertEqual(result.returncode, 124)
        self.assertNotIn(b"cccc-timeout:", result.stderr)

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


class TimeoutRunnerUnitTests(unittest.TestCase):
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
        with mock.patch.object(
            RUNNER_MODULE.subprocess, "Popen", side_effect=OSError("launch failed")
        ):
            RUNNER_MODULE.run(["1", "--", "child"])
        self.assertIs(signal.getsignal(signal.SIGTERM), previous)

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
            return job, None

        gate.set.side_effect = lambda: events.append("set") or None
        with mock.patch.object(RUNNER_MODULE, "WindowsGate", return_value=gate), \
             mock.patch.object(
                 RUNNER_MODULE.subprocess, "CREATE_NEW_PROCESS_GROUP", 0x00000200, create=True
             ), \
             mock.patch.object(RUNNER_MODULE.subprocess, "Popen", side_effect=launch), \
             mock.patch.object(RUNNER_MODULE, "create_windows_job", side_effect=assign):
            bootstrap, created_gate, assigned_job, error = RUNNER_MODULE.launch_windows_bootstrap(
                ["target", "argument"]
            )

        self.assertIs(bootstrap, process)
        self.assertIs(created_gate, gate)
        self.assertIs(assigned_job, job)
        self.assertIsNone(error)
        self.assertEqual(events, ["popen", "assign", "set"])

    def test_windows_assignment_failure_never_releases_gate(self):
        process = mock.Mock()
        gate = mock.Mock()
        gate.name = "Local\\cccc-test-gate"
        with mock.patch.object(RUNNER_MODULE, "WindowsGate", return_value=gate), \
             mock.patch.object(
                 RUNNER_MODULE.subprocess, "CREATE_NEW_PROCESS_GROUP", 0x00000200, create=True
             ), \
             mock.patch.object(RUNNER_MODULE.subprocess, "Popen", return_value=process), \
             mock.patch.object(
                 RUNNER_MODULE, "create_windows_job", return_value=(None, "assignment failed")
             ):
            _bootstrap, _gate, _job, error = RUNNER_MODULE.launch_windows_bootstrap(["target"])

        self.assertIn("assignment failed", error)
        gate.set.assert_not_called()

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
        with mock.patch.object(RUNNER_MODULE, "process_group_exists", return_value=True), \
             mock.patch.object(RUNNER_MODULE.os, "killpg") as killpg, \
             mock.patch.object(RUNNER_MODULE.time, "monotonic", side_effect=[10, 11.99, 12]), \
             mock.patch.object(RUNNER_MODULE.time, "sleep") as sleep:
            RUNNER_MODULE.stop_posix(process)

        sleep.assert_called_once()
        self.assertAlmostEqual(sleep.call_args.args[0], 0.01)
        self.assertEqual(
            [call.args[1] for call in killpg.call_args_list],
            [RUNNER_MODULE.signal.SIGTERM, RUNNER_MODULE.signal.SIGKILL],
        )
        process.wait.assert_called_once_with(timeout=2)

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
        with mock.patch.object(RUNNER_MODULE.subprocess, "Popen", return_value=process), \
             mock.patch.object(RUNNER_MODULE, "stop_process", return_value="SIGTERM failed: denied"), \
             mock.patch.object(RUNNER_MODULE.sys, "stderr", stderr):
            status = RUNNER_MODULE.run(["1", "--", "child"])

        self.assertEqual(status, 125)
        self.assertIn("cccc-timeout: command exceeded 1 seconds", stderr.getvalue())
        self.assertIn("cccc-timeout: cleanup failed: SIGTERM failed: denied", stderr.getvalue())

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
        process.wait.side_effect = subprocess.TimeoutExpired(["child"], 2)
        with mock.patch.object(RUNNER_MODULE, "process_group_exists", return_value=True), \
             mock.patch.object(RUNNER_MODULE.os, "killpg"), \
             mock.patch.object(RUNNER_MODULE.time, "monotonic", side_effect=[0, 2]):
            error = RUNNER_MODULE.stop_posix(process)

        self.assertIn("did not exit", error)
        process.wait.assert_called_once_with(timeout=2)


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

    def test_runner_interrupt_cleans_descendants_and_preserves_signal(self):
        child_code = (
            "import os, subprocess, sys, time;"
            "grandchild = subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(30)']);"
            "print(f'{os.getpid()} {grandchild.pid}', flush=True);"
            "time.sleep(30)"
        )
        for interrupted_by in (signal.SIGTERM, signal.SIGINT):
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
