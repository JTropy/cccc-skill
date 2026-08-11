from __future__ import annotations

import errno
import hashlib
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

    def run_publish(
        self,
        source: Path,
        destination: Path,
        parent_identity: str | None = None,
        source_identity: str | None = None,
        source_sha256: str | None = None,
    ) -> subprocess.CompletedProcess[str]:
        arguments = [sys.executable, "-I", str(PUBLISHER)]
        if parent_identity is not None:
            arguments.extend(["--parent-identity", parent_identity])
        if source_identity is not None:
            arguments.extend(["--source-identity", source_identity])
        if source_sha256 is not None:
            arguments.extend(["--source-sha256", source_sha256])
        arguments.extend([str(source), str(destination)])
        return subprocess.run(
            arguments,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )

    def capture_parent_identity(self, destination: Path) -> str:
        result = subprocess.run(
            [sys.executable, "-I", str(PUBLISHER), "--print-parent-identity", str(destination)],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )
        self.assertEqual(0, result.returncode, result.stderr)
        return result.stdout.strip()

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

    def test_expected_parent_identity_allows_normal_publication(self) -> None:
        parent = self.root / "output"
        parent.mkdir()
        source = self.root / "source"
        destination = parent / "result.md"
        source.write_bytes(b"payload")
        identity = self.capture_parent_identity(destination)

        result = self.run_publish(source, destination, identity)

        self.assertEqual(0, result.returncode, result.stderr)
        self.assertEqual(b"payload", destination.read_bytes())

    def test_expected_source_identity_and_digest_allow_normal_publication(self) -> None:
        source = self.root / "source"
        destination = self.root / "destination"
        payload = b"bound payload"
        source.write_bytes(payload)
        value = os.stat(source, follow_symlinks=False)
        identity = f"{value.st_dev}:{value.st_ino}"
        digest = hashlib.sha256(payload).hexdigest()

        result = self.run_publish(
            source,
            destination,
            source_identity=identity,
            source_sha256=digest,
        )

        self.assertEqual(0, result.returncode, result.stderr)
        self.assertEqual(payload, destination.read_bytes())

    def test_expected_source_identity_rejects_preopen_replacement(self) -> None:
        source = self.root / "source"
        original = self.root / "original-source"
        destination = self.root / "destination"
        source.write_bytes(b"trusted")
        value = os.stat(source, follow_symlinks=False)
        identity = f"{value.st_dev}:{value.st_ino}"
        source.rename(original)
        source.write_bytes(b"forged")

        result = self.run_publish(source, destination, source_identity=identity)

        self.assertEqual(5, result.returncode, result.stderr)
        self.assertFalse(destination.exists())
        self.assertEqual(b"forged", source.read_bytes())
        self.assertEqual(b"trusted", original.read_bytes())
        self.assert_no_temps()

    def test_expected_source_digest_rejects_same_inode_mutation(self) -> None:
        source = self.root / "source"
        destination = self.root / "destination"
        source.write_bytes(b"trusted")
        value = os.stat(source, follow_symlinks=False)
        identity = f"{value.st_dev}:{value.st_ino}"
        digest = hashlib.sha256(b"trusted").hexdigest()
        source.write_bytes(b"forged")

        result = self.run_publish(
            source,
            destination,
            source_identity=identity,
            source_sha256=digest,
        )

        self.assertEqual(5, result.returncode, result.stderr)
        self.assertFalse(destination.exists())
        self.assertEqual(b"forged", source.read_bytes())
        self.assert_no_temps()

    def test_source_reparse_metadata_is_rejected_before_open(self) -> None:
        module = self.load_module()
        source = self.root / "source"
        source.write_bytes(b"payload")
        actual = os.lstat(source)
        reparse = mock.Mock(
            st_mode=actual.st_mode,
            st_dev=actual.st_dev,
            st_ino=actual.st_ino,
            st_file_attributes=0x400,
            st_reparse_tag=0,
        )

        with mock.patch.object(module.os, "lstat", return_value=reparse):
            with self.assertRaises(module.PublishError):
                module._open_verified_source(source)

    def test_expected_parent_identity_rejects_symlink_replacement(self) -> None:
        parent = self.root / "output"
        moved_parent = self.root / "original-output"
        outside = self.root / "outside"
        parent.mkdir()
        outside.mkdir()
        source = self.root / "source"
        destination = parent / "result.md"
        referent = outside / "referent.md"
        source.write_bytes(b"payload")
        referent.write_bytes(b"keep")
        identity = self.capture_parent_identity(destination)
        parent.rename(moved_parent)
        try:
            parent.symlink_to(outside, target_is_directory=True)
        except (OSError, NotImplementedError) as error:
            self.skipTest(f"directory symlink unavailable: {error}")

        result = self.run_publish(source, destination, identity)

        self.assertEqual(5, result.returncode, result.stderr)
        self.assertFalse((outside / destination.name).exists())
        self.assertEqual(b"keep", referent.read_bytes())
        self.assertFalse((moved_parent / destination.name).exists())

    def test_expected_parent_identity_rejects_new_directory_at_same_path(self) -> None:
        parent = self.root / "output"
        moved_parent = self.root / "original-output"
        parent.mkdir()
        source = self.root / "source"
        destination = parent / "result.md"
        source.write_bytes(b"payload")
        identity = self.capture_parent_identity(destination)
        parent.rename(moved_parent)
        parent.mkdir()

        result = self.run_publish(source, destination, identity)

        self.assertEqual(5, result.returncode, result.stderr)
        self.assertFalse(destination.exists())
        self.assertFalse((moved_parent / destination.name).exists())

    @unittest.skipUnless(os.name == "posix", "requires POSIX directory descriptors")
    def test_parent_swap_after_open_never_publishes_through_external_symlink(self) -> None:
        module = self.load_module()
        if not module._supports_pinned_dirfd():
            self.skipTest("POSIX open/stat/link/unlink dir_fd support unavailable")
        parent = self.root / "output"
        moved_parent = self.root / "original-output"
        outside = self.root / "outside"
        parent.mkdir()
        outside.mkdir()
        source = self.root / "source"
        destination = parent / "result.md"
        source.write_bytes(b"payload")
        identity = self.capture_parent_identity(destination)
        real_open_source = module._open_verified_source
        swapped = False

        def open_source_then_swap(path):
            nonlocal swapped
            result = real_open_source(path)
            if not swapped:
                swapped = True
                parent.rename(moved_parent)
                parent.symlink_to(outside, target_is_directory=True)
            return result

        stderr = StringIO()
        with redirect_stderr(stderr), mock.patch.object(
            module, "_open_verified_source", side_effect=open_source_then_swap
        ):
            result = module.main(
                ["--parent-identity", identity, str(source), str(destination)]
            )

        self.assertIn(result, (0, 5), stderr.getvalue())
        self.assertFalse((outside / destination.name).exists())
        self.assertEqual([], list(outside.glob(".cccc-publish-*")))
        if result == 0:
            self.assertEqual(b"payload", (moved_parent / destination.name).read_bytes())
        else:
            self.assertFalse((moved_parent / destination.name).exists())

    @unittest.skipUnless(os.name == "nt", "requires Windows junction semantics")
    def test_expected_parent_identity_rejects_windows_junction_replacement(self) -> None:
        parent = self.root / "output"
        moved_parent = self.root / "original-output"
        outside = self.root / "outside"
        parent.mkdir()
        outside.mkdir()
        source = self.root / "source"
        destination = parent / "result.md"
        source.write_bytes(b"payload")
        identity = self.capture_parent_identity(destination)
        parent.rename(moved_parent)
        junction = subprocess.run(
            ["cmd.exe", "/d", "/c", "mklink", "/J", str(parent), str(outside)],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )
        if junction.returncode != 0:
            self.skipTest(f"junction creation unavailable: {junction.stderr or junction.stdout}")

        result = self.run_publish(source, destination, identity)

        self.assertEqual(5, result.returncode, result.stderr)
        self.assertFalse((outside / destination.name).exists())

    @unittest.skipUnless(os.name == "posix", "requires directory symlink replacement")
    def test_fallback_cleanup_never_unlinks_same_named_external_file(self) -> None:
        module = self.load_module()
        parent = self.root / "output"
        moved_parent = self.root / "original-output"
        outside = self.root / "outside"
        parent.mkdir()
        outside.mkdir()
        source = self.root / "source"
        destination = parent / "result.md"
        source.write_bytes(b"payload")
        identity = self.capture_parent_identity(destination)
        real_mkstemp = module.tempfile.mkstemp
        temp_name = None

        def create_temp_then_swap(*args, **kwargs):
            nonlocal temp_name
            descriptor, raw_path = real_mkstemp(*args, **kwargs)
            temp_name = Path(raw_path).name
            parent.rename(moved_parent)
            parent.symlink_to(outside, target_is_directory=True)
            (outside / temp_name).write_bytes(b"keep")
            return descriptor, raw_path

        stderr = StringIO()
        with redirect_stderr(stderr), mock.patch.object(
            module, "_PINNED_DIRFD_SUPPORTED", False
        ), mock.patch.object(module.tempfile, "mkstemp", side_effect=create_temp_then_swap):
            result = module.main(
                ["--parent-identity", identity, str(source), str(destination)]
            )

        self.assertEqual(5, result, stderr.getvalue())
        self.assertIsNotNone(temp_name)
        assert temp_name is not None
        self.assertEqual(b"keep", (outside / temp_name).read_bytes())
        self.assertTrue((moved_parent / temp_name).exists())
        self.assertIn("warning", stderr.getvalue().lower())

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
        real_unlink = module.os.unlink

        def fail_owned_temp(path, *args, **kwargs):
            if Path(path).name.startswith(".cccc-publish-"):
                raise PermissionError(errno.EACCES, "simulated cleanup denial")
            return real_unlink(path, *args, **kwargs)

        stderr = StringIO()
        with redirect_stderr(stderr), mock.patch.object(module.os, "unlink", fail_owned_temp):
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

    def test_source_metadata_change_during_copy_is_not_published(self) -> None:
        module = self.load_module()
        source = self.root / "source"
        destination = self.root / "destination"
        source.write_bytes(b"original")
        real_copy = module.shutil.copyfileobj

        def copy_then_mutate(source_stream, destination_stream, *args, **kwargs):
            result = real_copy(source_stream, destination_stream, *args, **kwargs)
            with source.open("ab") as stream:
                stream.write(b"-changed")
                stream.flush()
                os.fsync(stream.fileno())
            return result

        stderr = StringIO()
        with redirect_stderr(stderr), mock.patch.object(
            module.shutil, "copyfileobj", side_effect=copy_then_mutate
        ):
            result = module.main([str(source), str(destination)])

        self.assertEqual(5, result)
        self.assertFalse(os.path.lexists(destination))
        self.assertIn("source", stderr.getvalue().lower())
        self.assert_no_temps()

    def test_source_path_inode_change_during_copy_is_not_published(self) -> None:
        module = self.load_module()
        source = self.root / "source"
        moved = self.root / "moved-source"
        destination = self.root / "destination"
        source.write_bytes(b"original")
        real_copy = module.shutil.copyfileobj

        def copy_then_replace(source_stream, destination_stream, *args, **kwargs):
            result = real_copy(source_stream, destination_stream, *args, **kwargs)
            source.rename(moved)
            source.write_bytes(b"replacement")
            return result

        stderr = StringIO()
        with redirect_stderr(stderr), mock.patch.object(
            module.shutil, "copyfileobj", side_effect=copy_then_replace
        ):
            result = module.main([str(source), str(destination)])

        self.assertEqual(5, result)
        self.assertFalse(os.path.lexists(destination))
        if moved.exists():
            self.assertEqual(b"original", moved.read_bytes())
        else:
            # Windows may keep the opened source path bound while the callback
            # replaces its contents; the security property is still that the
            # changed source is detected and never published.
            self.assertEqual(b"replacement", source.read_bytes())
        self.assert_no_temps()

    def test_primary_failure_also_warns_when_owned_temp_cleanup_fails(self) -> None:
        module = self.load_module()
        source = self.root / "source"
        destination = self.root / "destination"
        source.write_bytes(b"payload")
        real_unlink = module.os.unlink

        def fail_owned_temp(path, *args, **kwargs):
            if Path(path).name.startswith(".cccc-publish-"):
                raise PermissionError(errno.EACCES, "simulated cleanup denial")
            return real_unlink(path, *args, **kwargs)

        stderr = StringIO()
        with redirect_stderr(stderr), mock.patch.object(
            module.os, "link", side_effect=OSError(errno.EXDEV, "simulated link failure")
        ), mock.patch.object(module.os, "unlink", fail_owned_temp):
            result = module.main([str(source), str(destination)])

        self.assertEqual(5, result)
        self.assertFalse(os.path.lexists(destination))
        self.assertIn("hard-link publication", stderr.getvalue())
        self.assertIn("warning", stderr.getvalue().lower())
        leaked = list(self.root.glob(".cccc-publish-*"))
        self.assertEqual(1, len(leaked))
        leaked[0].unlink()


if __name__ == "__main__":
    unittest.main()
