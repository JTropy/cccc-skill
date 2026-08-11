#!/usr/bin/env python3
"""Publish one regular file without replacing an existing destination."""

from __future__ import annotations

import hashlib
import os
import re
import secrets
import shutil
import stat
import sys
import tempfile
from pathlib import Path
from typing import Optional, Sequence


USAGE_ERROR = 2
PUBLISH_ERROR = 5
FILE_ATTRIBUTE_REPARSE_POINT = 0x00000400


class PublishError(Exception):
    """A safety check or atomic publication step failed."""


def _identity(value) -> tuple[int, int]:
    return value.st_dev, value.st_ino


def _format_identity(value) -> str:
    device, inode = _identity(value)
    return f"{device}:{inode}"


def _parse_identity(value: str, subject: str = "destination parent") -> tuple[int, int]:
    fields = value.split(":")
    if (
        len(fields) != 2
        or any(not field.isascii() or not field.isdecimal() for field in fields)
        or any(str(int(field)) != field for field in fields)
    ):
        raise PublishError(f"{subject} identity must be DEV:INO decimal integers")
    return int(fields[0]), int(fields[1])


def _parse_sha256(value: str) -> str:
    if re.fullmatch(r"[0-9a-f]{64}", value) is None:
        raise PublishError("source SHA-256 must be exactly 64 lowercase hexadecimal characters")
    return value


def _is_reparse_point(value) -> bool:
    return bool(
        getattr(value, "st_file_attributes", 0) & FILE_ATTRIBUTE_REPARSE_POINT
        or getattr(value, "st_reparse_tag", 0)
    )


def _require_plain_directory(value, message: str) -> None:
    if stat.S_ISLNK(value.st_mode) or _is_reparse_point(value):
        raise PublishError(f"{message} must not be a symlink or reparse point")
    if not stat.S_ISDIR(value.st_mode):
        raise PublishError(f"{message} must be a directory")


def _open_windows_directory(path: Path) -> int:
    import ctypes
    import msvcrt
    from ctypes import wintypes

    file_read_attributes = 0x00000080
    file_share_all = 0x00000001 | 0x00000002 | 0x00000004
    open_existing = 3
    file_flag_backup_semantics = 0x02000000
    file_flag_open_reparse_point = 0x00200000
    kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
    kernel32.CreateFileW.argtypes = [
        wintypes.LPCWSTR,
        wintypes.DWORD,
        wintypes.DWORD,
        ctypes.c_void_p,
        wintypes.DWORD,
        wintypes.DWORD,
        wintypes.HANDLE,
    ]
    kernel32.CreateFileW.restype = wintypes.HANDLE
    kernel32.CloseHandle.argtypes = [wintypes.HANDLE]
    kernel32.CloseHandle.restype = wintypes.BOOL
    handle = kernel32.CreateFileW(
        str(path),
        file_read_attributes,
        file_share_all,
        None,
        open_existing,
        file_flag_backup_semantics | file_flag_open_reparse_point,
        None,
    )
    if handle == ctypes.c_void_p(-1).value:
        raise ctypes.WinError(ctypes.get_last_error())
    try:
        return msvcrt.open_osfhandle(handle, os.O_RDONLY)
    except BaseException:
        kernel32.CloseHandle(handle)
        raise


def _open_directory(path: Path) -> int:
    if os.name == "nt":
        return _open_windows_directory(path)
    flags = os.O_RDONLY
    if os.name == "posix":
        if not hasattr(os, "O_DIRECTORY") or not hasattr(os, "O_NOFOLLOW"):
            raise PublishError("safe destination parent opening is unavailable")
        flags |= os.O_DIRECTORY | os.O_NOFOLLOW
    try:
        return os.open(path, flags)
    except OSError as error:
        raise PublishError(f"cannot safely open destination parent: {error}") from error


def _open_verified_parent(
    path: Path, expected_identity: tuple[int, int] | None = None
) -> tuple[int, object]:
    try:
        before = os.lstat(path)
    except OSError as error:
        raise PublishError(f"cannot inspect destination parent: {error}") from error
    _require_plain_directory(before, "destination parent")

    descriptor = _open_directory(path)
    try:
        opened = os.fstat(descriptor)
        _require_plain_directory(opened, "opened destination parent")
        if _identity(before) != _identity(opened):
            raise PublishError("destination parent changed while opening")
        if expected_identity is not None and expected_identity != _identity(opened):
            raise PublishError("destination parent identity changed")
    except BaseException:
        os.close(descriptor)
        raise
    return descriptor, opened


def capture_parent_identity(destination: Path) -> str:
    if not destination.name:
        raise PublishError("destination must name a file")
    descriptor, opened = _open_verified_parent(destination.parent)
    try:
        return _format_identity(opened)
    finally:
        os.close(descriptor)


def _open_verified_source(
    path: Path,
    expected_identity: tuple[int, int] | None = None,
    expected_sha256: str | None = None,
):
    try:
        before = os.lstat(path)
    except OSError as error:
        raise PublishError(f"cannot inspect source: {error}") from error
    if stat.S_ISLNK(before.st_mode) or _is_reparse_point(before) or not stat.S_ISREG(before.st_mode):
        raise PublishError("source must be a regular, non-symlink, non-reparse file")

    flags = os.O_RDONLY
    flags |= getattr(os, "O_NONBLOCK", 0)
    flags |= getattr(os, "O_NOFOLLOW", 0)
    try:
        descriptor = os.open(path, flags)
    except OSError as error:
        raise PublishError(f"cannot safely open source: {error}") from error

    try:
        opened = os.fstat(descriptor)
        if not stat.S_ISREG(opened.st_mode) or _is_reparse_point(opened):
            raise PublishError("source changed type while opening")
        if _identity(before) != _identity(opened):
            raise PublishError("source changed while opening")
        if expected_identity is not None and _identity(opened) != expected_identity:
            raise PublishError("source identity changed")
        if expected_sha256 is not None:
            hasher = hashlib.sha256()
            while True:
                chunk = os.read(descriptor, 1024 * 1024)
                if not chunk:
                    break
                hasher.update(chunk)
            after_digest = os.fstat(descriptor)
            if _is_reparse_point(after_digest) or _identity(after_digest) != _identity(opened):
                raise PublishError("source changed while hashing")
            before_metadata = (opened.st_size, opened.st_mtime_ns, opened.st_ctime_ns)
            after_metadata = (
                after_digest.st_size,
                after_digest.st_mtime_ns,
                after_digest.st_ctime_ns,
            )
            if before_metadata != after_metadata:
                raise PublishError("source changed while hashing")
            if not secrets.compare_digest(hasher.hexdigest(), expected_sha256):
                raise PublishError("source SHA-256 changed")
            os.lseek(descriptor, 0, os.SEEK_SET)
    except BaseException:
        os.close(descriptor)
        raise
    return descriptor, opened


def _verify_source_after_copy(path: Path, descriptor: int, opened_stat) -> None:
    copied_stat = os.fstat(descriptor)
    if _is_reparse_point(copied_stat):
        raise PublishError("opened source became a reparse point")
    opened_metadata = (
        opened_stat.st_size,
        opened_stat.st_mtime_ns,
        opened_stat.st_ctime_ns,
    )
    copied_metadata = (
        copied_stat.st_size,
        copied_stat.st_mtime_ns,
        copied_stat.st_ctime_ns,
    )
    if opened_metadata != copied_metadata:
        raise PublishError("source changed while being copied")
    try:
        current_path_stat = os.lstat(path)
    except OSError as error:
        raise PublishError(f"source path changed while being copied: {error}") from error
    if (
        stat.S_ISLNK(current_path_stat.st_mode)
        or _is_reparse_point(current_path_stat)
        or not stat.S_ISREG(current_path_stat.st_mode)
    ):
        raise PublishError("source path changed type while being copied")
    if _identity(current_path_stat) != _identity(copied_stat):
        raise PublishError("source path changed identity while being copied")


def _detect_pinned_dirfd_support() -> bool:
    supported = getattr(os, "supports_dir_fd", set())
    return (
        os.name == "posix"
        and hasattr(os, "O_DIRECTORY")
        and hasattr(os, "O_NOFOLLOW")
        and all(function in supported for function in (os.open, os.stat, os.link, os.unlink))
    )


_PINNED_DIRFD_SUPPORTED = _detect_pinned_dirfd_support()


def _supports_pinned_dirfd() -> bool:
    return _PINNED_DIRFD_SUPPORTED


def _destination_absent_at(parent_fd: int, name: str) -> None:
    try:
        os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
    except FileNotFoundError:
        return
    except OSError as error:
        raise PublishError(f"cannot inspect destination: {error}") from error
    raise PublishError("destination already exists")


def _create_temp_at(parent_fd: int) -> tuple[int, str]:
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
    flags |= getattr(os, "O_CLOEXEC", 0)
    for _attempt in range(100):
        name = f".cccc-publish-{secrets.token_hex(16)}"
        try:
            return os.open(name, flags, 0o600, dir_fd=parent_fd), name
        except FileExistsError:
            continue
        except OSError as error:
            raise PublishError(
                f"cannot create destination-side temporary file: {error}"
            ) from error
    raise PublishError("cannot allocate a unique destination-side temporary file")


def _copy_to_descriptor(
    source: Path, source_fd: int, source_opened_stat, temp_fd: int
) -> None:
    with os.fdopen(source_fd, "rb", closefd=True) as source_stream:
        with os.fdopen(temp_fd, "wb", closefd=True) as destination_stream:
            shutil.copyfileobj(source_stream, destination_stream)
            destination_stream.flush()
            os.fsync(destination_stream.fileno())
            _verify_source_after_copy(source, source_stream.fileno(), source_opened_stat)


def _report_cleanup_error(error: BaseException, committed: bool, failure_in_progress: bool) -> None:
    if committed:
        print(
            "cccc publish: warning: destination committed, but owned temporary "
            f"file cleanup failed: {error}",
            file=sys.stderr,
        )
    elif failure_in_progress:
        print(
            "cccc publish: warning: publication failed and owned temporary "
            f"file cleanup also failed: {error}",
            file=sys.stderr,
        )
    else:
        raise PublishError(f"cannot remove owned temporary file: {error}")


def _publish_with_dirfd(
    source: Path,
    destination_name: str,
    parent_fd: int,
    expected_source_identity: tuple[int, int] | None,
    expected_source_sha256: str | None,
) -> None:
    _destination_absent_at(parent_fd, destination_name)
    if expected_source_identity is None and expected_source_sha256 is None:
        source_fd, source_opened_stat = _open_verified_source(source)
    else:
        source_fd, source_opened_stat = _open_verified_source(
            source, expected_source_identity, expected_source_sha256
        )
    temp_fd = None  # type: Optional[int]
    temp_name = None  # type: Optional[str]
    cleanup_error = None  # type: Optional[OSError]
    committed = False
    try:
        temp_fd, temp_name = _create_temp_at(parent_fd)
        owned_source_fd, source_fd = source_fd, -1
        owned_temp_fd, temp_fd = temp_fd, None
        _copy_to_descriptor(source, owned_source_fd, source_opened_stat, owned_temp_fd)
        try:
            os.link(
                temp_name,
                destination_name,
                src_dir_fd=parent_fd,
                dst_dir_fd=parent_fd,
                follow_symlinks=False,
            )
            committed = True
        except FileExistsError as error:
            raise PublishError("destination appeared during publication") from error
        except OSError as error:
            raise PublishError(f"atomic hard-link publication is unavailable: {error}") from error
    finally:
        failure_in_progress = sys.exc_info()[0] is not None
        if source_fd >= 0:
            os.close(source_fd)
        if temp_fd is not None and temp_fd >= 0:
            os.close(temp_fd)
        if temp_name is not None:
            try:
                os.unlink(temp_name, dir_fd=parent_fd)
            except FileNotFoundError:
                pass
            except OSError as error:
                cleanup_error = error
        if cleanup_error is not None:
            _report_cleanup_error(cleanup_error, committed, failure_in_progress)


def _verify_parent_path(path: Path, expected_identity: tuple[int, int]) -> None:
    try:
        current = os.lstat(path)
    except OSError as error:
        raise PublishError(f"cannot recheck destination parent: {error}") from error
    _require_plain_directory(current, "destination parent")
    if _identity(current) != expected_identity:
        raise PublishError("destination parent identity changed")


def _unlink_verified_fallback_temp(
    temp_path: Path,
    temp_identity: tuple[int, int],
    parent_path: Path,
    parent_identity: tuple[int, int],
) -> BaseException | None:
    try:
        _verify_parent_path(parent_path, parent_identity)
        current = os.lstat(temp_path)
        if (
            stat.S_ISLNK(current.st_mode)
            or _is_reparse_point(current)
            or not stat.S_ISREG(current.st_mode)
        ):
            raise PublishError("owned temporary path changed type before cleanup")
        if _identity(current) != temp_identity:
            raise PublishError("owned temporary path changed identity before cleanup")
        os.unlink(temp_path)
    except FileNotFoundError:
        return None
    except (PublishError, OSError) as error:
        return error
    return None


def _publish_without_dirfd(
    source: Path,
    destination: Path,
    parent_identity: tuple[int, int],
    expected_source_identity: tuple[int, int] | None,
    expected_source_sha256: str | None,
) -> None:
    _verify_parent_path(destination.parent, parent_identity)
    try:
        os.lstat(destination)
    except FileNotFoundError:
        pass
    except OSError as error:
        raise PublishError(f"cannot inspect destination: {error}") from error
    else:
        raise PublishError("destination already exists")

    if expected_source_identity is None and expected_source_sha256 is None:
        source_fd, source_opened_stat = _open_verified_source(source)
    else:
        source_fd, source_opened_stat = _open_verified_source(
            source, expected_source_identity, expected_source_sha256
        )
    temp_fd = None  # type: Optional[int]
    temp_path = None  # type: Optional[Path]
    temp_identity = None  # type: Optional[tuple[int, int]]
    cleanup_error = None  # type: Optional[BaseException]
    committed = False
    try:
        _verify_parent_path(destination.parent, parent_identity)
        try:
            temp_fd, raw_temp_path = tempfile.mkstemp(
                prefix=".cccc-publish-", dir=str(destination.parent)
            )
            temp_path = Path(raw_temp_path)
            temp_opened = os.fstat(temp_fd)
            if not stat.S_ISREG(temp_opened.st_mode):
                raise PublishError("destination-side temporary file changed type")
            temp_identity = _identity(temp_opened)
        except OSError as error:
            raise PublishError(
                f"cannot create destination-side temporary file: {error}"
            ) from error
        _verify_parent_path(destination.parent, parent_identity)
        owned_source_fd, source_fd = source_fd, -1
        owned_temp_fd, temp_fd = temp_fd, None
        _copy_to_descriptor(source, owned_source_fd, source_opened_stat, owned_temp_fd)
        _verify_parent_path(destination.parent, parent_identity)
        try:
            os.link(temp_path, destination)
            committed = True
        except FileExistsError as error:
            raise PublishError("destination appeared during publication") from error
        except OSError as error:
            raise PublishError(f"atomic hard-link publication is unavailable: {error}") from error
        _verify_parent_path(destination.parent, parent_identity)
    finally:
        failure_in_progress = sys.exc_info()[0] is not None
        if source_fd >= 0:
            os.close(source_fd)
        if temp_fd is not None and temp_fd >= 0:
            os.close(temp_fd)
        if temp_path is not None and temp_identity is not None:
            cleanup_error = _unlink_verified_fallback_temp(
                temp_path,
                temp_identity,
                destination.parent,
                parent_identity,
            )
        elif temp_path is not None:
            cleanup_error = PublishError(
                "owned temporary identity was unavailable; refusing path cleanup"
            )
        if cleanup_error is not None:
            _report_cleanup_error(cleanup_error, committed, failure_in_progress)


def publish(
    source: Path,
    destination: Path,
    expected_parent_identity: str | None = None,
    expected_source_identity: str | None = None,
    expected_source_sha256: str | None = None,
) -> None:
    """Copy source, fsync it, then hard-link it beneath a verified parent."""
    if not source.name or not destination.name:
        raise PublishError("source and destination must name files")
    expected = (
        _parse_identity(expected_parent_identity)
        if expected_parent_identity is not None
        else None
    )
    source_identity = (
        _parse_identity(expected_source_identity, "source")
        if expected_source_identity is not None
        else None
    )
    source_sha256 = (
        _parse_sha256(expected_source_sha256)
        if expected_source_sha256 is not None
        else None
    )
    parent_fd, opened_parent = _open_verified_parent(destination.parent, expected)
    opened_identity = _identity(opened_parent)
    try:
        if _supports_pinned_dirfd():
            _publish_with_dirfd(
                source,
                destination.name,
                parent_fd,
                source_identity,
                source_sha256,
            )
        else:
            _publish_without_dirfd(
                source,
                destination,
                opened_identity,
                source_identity,
                source_sha256,
            )
    finally:
        os.close(parent_fd)


def main(argv: Sequence[str] | None = None) -> int:
    arguments = list(sys.argv[1:] if argv is None else argv)
    try:
        if len(arguments) == 2 and arguments[0] == "--print-parent-identity":
            print(capture_parent_identity(Path(arguments[1])))
            return 0
        options: dict[str, str] = {}
        while arguments and arguments[0].startswith("--"):
            option = arguments[0]
            if option not in {
                "--parent-identity",
                "--source-identity",
                "--source-sha256",
            }:
                print(
                    "usage: publish-no-clobber.py [--parent-identity DEV:INO] "
                    "[--source-identity DEV:INO] [--source-sha256 HEX] "
                    "SOURCE DESTINATION",
                    file=sys.stderr,
                )
                return USAGE_ERROR
            arguments.pop(0)
            if option in options or not arguments:
                raise PublishError(f"invalid or duplicate publisher option: {option}")
            options[option] = arguments.pop(0)
        if len(arguments) != 2:
            print(
                "usage: publish-no-clobber.py [--parent-identity DEV:INO] "
                "[--source-identity DEV:INO] [--source-sha256 HEX] "
                "SOURCE DESTINATION",
                file=sys.stderr,
            )
            return USAGE_ERROR
        publish(
            Path(arguments[0]),
            Path(arguments[1]),
            options.get("--parent-identity"),
            options.get("--source-identity"),
            options.get("--source-sha256"),
        )
    except (PublishError, OSError) as error:
        print(f"cccc publish: {error}", file=sys.stderr)
        return PUBLISH_ERROR
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
