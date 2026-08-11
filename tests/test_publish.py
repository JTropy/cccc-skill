from __future__ import annotations

import errno
import importlib.util
import os
import signal
import subprocess
import sys
import tempfile
import threading
import unittest
from contextlib import redirect_stderr
from io import StringIO
from pathlib import Path
from unittest import mock


ROOT = Path(__file__).resolve().parents[1]
PUBLISHER = ROOT / "skills" / "cccc" / "scripts" / "publish-no-clobber.py"


class PublishNoClobberTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp_dir = tempfile.TemporaryDirectory(prefix="cccc-publish-test-")
        self.root = Path(self.temp_dir.name)

    def tearDown(self) -> None:
        self.temp_dir.cleanup()

    def run_publish(self, source: Path, destination: Path) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [sys.executable, str(PUBLISHER), str(source), str(destination)],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )

    def assert_no_temps(self) -> None:
        self.assertEqual([], list(self.root.glob(".cccc-publish-*")))

    def load_module(self):
        self.assertTrue(PUBLISHER.is_file(), f"missing {PUBLISHER}")
        spec = importlib.util.spec_from_file_location("cccc_publisher", PUBLISHER)
        self.assertIsNotNone(spec)
        self.assertIsNotNone(spec.loader if spec else None)
        module = importlib.util.module_from_spec(spec)  # type: ignore[arg-type]
        assert spec is not None and spec.loader is not None
        spec.loader.exec_module(module)
        return module

    def test_requires_exactly_source_and_destination(self) -> None:
        self.assertTrue(PUBLISHER.is_file(), f"missing {PUBLISHER}")
        result = subprocess.run(
            [sys.executable, str(PUBLISHER)],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )
        self.assertEqual(2, result.returncode)

    def test_publishes_regular_source_without_changing_it(self) -> None:
        source = self.root / "source with space.md"
        destination = self.root / "发布.md"
        payload = b"fresh report\n"
        source.write_bytes(payload)

        result = self.run_publish(source, destination)

        self.assertEqual(0, result.returncode, result.stderr)
        self.assertEqual(payload, source.read_bytes())
        self.assertEqual(payload, destination.read_bytes())
        self.assertNotEqual(os.stat(source).st_ino, os.stat(destination).st_ino)
        self.assert_no_temps()

    def test_existing_regular_destination_is_never_changed(self) -> None:
        source = self.root / "source"
        destination = self.root / "destination"
        source.write_bytes(b"new")
        destination.write_bytes(b"keep")

        result = self.run_publish(source, destination)

        self.assertEqual(5, result.returncode)
        self.assertEqual(b"keep", destination.read_bytes())
        self.assertEqual(b"new", source.read_bytes())
        self.assert_no_temps()

    def test_symlink_source_is_rejected(self) -> None:
        referent = self.root / "referent"
        source = self.root / "source"
        destination = self.root / "destination"
        referent.write_bytes(b"payload")
        try:
            source.symlink_to(referent.name)
        except (OSError, NotImplementedError) as error:
            self.skipTest(f"symlink unavailable: {error}")

        result = self.run_publish(source, destination)

        self.assertEqual(5, result.returncode)
        self.assertFalse(destination.exists())
        self.assertEqual(b"payload", referent.read_bytes())
        self.assert_no_temps()

    def test_fifo_source_is_rejected_without_opening_it(self) -> None:
        if not hasattr(os, "mkfifo"):
            self.skipTest("FIFO unavailable")
        source = self.root / "source"
        destination = self.root / "destination"
        try:
            os.mkfifo(source)
        except OSError as error:
            self.skipTest(f"FIFO unavailable: {error}")

        result = self.run_publish(source, destination)

        self.assertEqual(5, result.returncode)
        self.assertFalse(destination.exists())
        self.assert_no_temps()

    def test_preflight_then_symlink_injection_preserves_referent(self) -> None:
        source = self.root / "source"
        destination = self.root / "destination"
        referent = self.root / "referent"
        source.write_bytes(b"new")
        referent.write_bytes(b"keep")
        self.assertFalse(os.path.lexists(destination))
        try:
            destination.symlink_to(referent.name)
        except (OSError, NotImplementedError) as error:
            self.skipTest(f"symlink unavailable: {error}")

        result = self.run_publish(source, destination)

        self.assertEqual(5, result.returncode)
        self.assertTrue(destination.is_symlink())
        self.assertEqual(b"keep", referent.read_bytes())
        self.assert_no_temps()

    def test_dangling_destination_symlink_is_rejected(self) -> None:
        source = self.root / "source"
        destination = self.root / "destination"
        source.write_bytes(b"new")
        try:
            destination.symlink_to("missing-referent")
        except (OSError, NotImplementedError) as error:
            self.skipTest(f"symlink unavailable: {error}")

        result = self.run_publish(source, destination)

        self.assertEqual(5, result.returncode)
        self.assertTrue(destination.is_symlink())
        self.assertFalse(destination.exists())
        self.assert_no_temps()

    def test_preflight_then_fifo_injection_fails_without_blocking(self) -> None:
        if not hasattr(os, "mkfifo"):
            self.skipTest("FIFO unavailable")
        source = self.root / "source"
        destination = self.root / "destination"
        source.write_bytes(b"new")
        self.assertFalse(os.path.lexists(destination))
        try:
            os.mkfifo(destination)
        except OSError as error:
            self.skipTest(f"FIFO unavailable: {error}")

        result = self.run_publish(source, destination)

        self.assertEqual(5, result.returncode)
        self.assertTrue(destination.exists())
        self.assert_no_temps()

    def test_publishers_synchronize_at_link_and_have_exactly_one_winner(self) -> None:
        source_a = self.root / "source-a"
        source_b = self.root / "source-b"
        destination = self.root / "destination"
        source_a.write_bytes(b"A")
        source_b.write_bytes(b"B")
        module = self.load_module()
        real_link = os.link
        link_barrier = threading.Barrier(2, timeout=10)
        outcomes = []
        outcome_lock = threading.Lock()

        def synchronized_link(source, target, *args, **kwargs):
            link_barrier.wait()
            return real_link(source, target, *args, **kwargs)

        def publish(source: Path) -> None:
            try:
                module.publish(source, destination)
                outcome = 0
            except module.PublishError:
                outcome = 5
            with outcome_lock:
                outcomes.append(outcome)

        with mock.patch.object(module.os, "link", side_effect=synchronized_link):
            threads = [threading.Thread(target=publish, args=(source,)) for source in (source_a, source_b)]
            for thread in threads:
                thread.start()
            for thread in threads:
                thread.join(timeout=10)
            self.assertFalse(any(thread.is_alive() for thread in threads), "publisher thread hung")

        self.assertEqual([0, 5], sorted(outcomes))
        self.assertIn(destination.read_bytes(), (b"A", b"B"))
        self.assertEqual(b"A", source_a.read_bytes())
        self.assertEqual(b"B", source_b.read_bytes())
        self.assert_no_temps()

    def test_unsupported_hard_links_fail_closed_without_fallback(self) -> None:
        module = self.load_module()
        source = self.root / "source"
        destination = self.root / "destination"
        source.write_bytes(b"payload")
        stderr = StringIO()
        with redirect_stderr(stderr), mock.patch.object(
            module.os, "link", side_effect=OSError(errno.EXDEV, "cross-device")
        ):
            result = module.main([str(source), str(destination)])

        self.assertEqual(5, result)
        self.assertFalse(os.path.lexists(destination))
        self.assertEqual(b"payload", source.read_bytes())
        self.assert_no_temps()

    def test_link_is_commit_point_when_owned_temp_cleanup_fails(self) -> None:
        module = self.load_module()
        source = self.root / "source"
        destination = self.root / "destination"
        source.write_bytes(b"payload")
        real_unlink = module.Path.unlink

        def fail_owned_temp(path, *args, **kwargs):
            if path.name.startswith(".cccc-publish-"):
                raise PermissionError(errno.EACCES, "simulated cleanup denial")
            return real_unlink(path, *args, **kwargs)

        stderr = StringIO()
        with redirect_stderr(stderr), mock.patch.object(module.Path, "unlink", fail_owned_temp):
            result = module.main([str(source), str(destination)])

        self.assertEqual(0, result, stderr.getvalue())
        self.assertEqual(b"payload", destination.read_bytes())
        self.assertIn("warning", stderr.getvalue().lower())
        leaked = list(self.root.glob(".cccc-publish-*"))
        self.assertEqual(1, len(leaked))
        leaked[0].unlink()

    def test_source_swap_to_symlink_between_lstat_and_open_fails_closed(self) -> None:
        module = self.load_module()
        source = self.root / "source"
        referent = self.root / "referent"
        destination = self.root / "destination"
        source.write_bytes(b"original")
        referent.write_bytes(b"secret")
        try:
            probe = self.root / "probe"
            probe.symlink_to(referent.name)
            probe.unlink()
        except (OSError, NotImplementedError) as error:
            self.skipTest(f"symlink unavailable: {error}")
        real_lstat = module.os.lstat
        swapped = False

        def swap_after_lstat(path):
            nonlocal swapped
            result = real_lstat(path)
            if Path(path) == source and not swapped:
                swapped = True
                source.unlink()
                source.symlink_to(referent.name)
            return result

        stderr = StringIO()
        with redirect_stderr(stderr), mock.patch.object(module.os, "lstat", side_effect=swap_after_lstat):
            result = module.main([str(source), str(destination)])

        self.assertEqual(5, result)
        self.assertFalse(destination.exists())
        self.assertEqual(b"secret", referent.read_bytes())
        self.assert_no_temps()

    def test_source_swap_to_fifo_between_lstat_and_open_never_blocks(self) -> None:
        if not hasattr(os, "mkfifo") or not hasattr(signal, "SIGALRM"):
            self.skipTest("FIFO or bounded alarm unavailable")
        module = self.load_module()
        source = self.root / "source"
        destination = self.root / "destination"
        source.write_bytes(b"original")
        real_lstat = module.os.lstat
        swapped = False

        def swap_after_lstat(path):
            nonlocal swapped
            result = real_lstat(path)
            if Path(path) == source and not swapped:
                swapped = True
                source.unlink()
                os.mkfifo(source)
            return result

        stderr = StringIO()
        previous_handler = signal.getsignal(signal.SIGALRM)

        def timeout_handler(_signum, _frame):
            raise TimeoutError("source FIFO open blocked")

        signal.signal(signal.SIGALRM, timeout_handler)
        signal.alarm(3)
        try:
            with redirect_stderr(stderr), mock.patch.object(
                module.os, "lstat", side_effect=swap_after_lstat
            ):
                result = module.main([str(source), str(destination)])
        finally:
            signal.alarm(0)
            signal.signal(signal.SIGALRM, previous_handler)

        self.assertEqual(5, result)
        self.assertFalse(destination.exists())
        self.assert_no_temps()


if __name__ == "__main__":
    unittest.main()
