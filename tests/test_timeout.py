"""Integration tests for the portable timeout runner."""

import os
from pathlib import Path
import subprocess
import sys
import time
import unittest


ROOT = Path(__file__).resolve().parents[1]
RUNNER = ROOT / "skills" / "cccc" / "scripts" / "run-with-timeout.py"


def command(*args):
    return [sys.executable, str(RUNNER), *args]


def child(code):
    return [sys.executable, "-c", code]


def pid_is_gone(pid):
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return True
    except PermissionError:
        return False
    return False


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


if __name__ == "__main__":
    unittest.main()
