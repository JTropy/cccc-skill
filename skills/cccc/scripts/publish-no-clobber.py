#!/usr/bin/env python3
"""Publish one regular file without ever replacing an existing destination."""

from __future__ import annotations

import os
import shutil
import stat
import sys
import tempfile
from pathlib import Path
from typing import Optional, Sequence


USAGE_ERROR = 2
PUBLISH_ERROR = 5


class PublishError(Exception):
    """A safety check or atomic publication step failed."""


def _open_verified_source(path: Path) -> int:
    try:
        before = os.lstat(path)
    except OSError as error:
        raise PublishError(f"cannot inspect source: {error}") from error
    if stat.S_ISLNK(before.st_mode) or not stat.S_ISREG(before.st_mode):
        raise PublishError("source must be a regular, non-symlink file")

    flags = os.O_RDONLY
    flags |= getattr(os, "O_NONBLOCK", 0)
    flags |= getattr(os, "O_NOFOLLOW", 0)
    try:
        descriptor = os.open(path, flags)
    except OSError as error:
        raise PublishError(f"cannot safely open source: {error}") from error

    try:
        opened = os.fstat(descriptor)
        if not stat.S_ISREG(opened.st_mode):
            raise PublishError("source changed type while opening")
        if (before.st_dev, before.st_ino) != (opened.st_dev, opened.st_ino):
            raise PublishError("source changed while opening")
    except BaseException:
        os.close(descriptor)
        raise
    return descriptor


def publish(source: Path, destination: Path) -> None:
    """Copy source, fsync it, then hard-link it to an absent destination."""

    if not source.name or not destination.name:
        raise PublishError("source and destination must name files")

    try:
        os.lstat(destination)
    except FileNotFoundError:
        pass
    except OSError as error:
        raise PublishError(f"cannot inspect destination: {error}") from error
    else:
        raise PublishError("destination already exists")

    source_fd = _open_verified_source(source)
    temp_fd = None  # type: Optional[int]
    temp_path = None  # type: Optional[Path]
    cleanup_error = None  # type: Optional[OSError]
    committed = False
    try:
        try:
            temp_fd, raw_temp_path = tempfile.mkstemp(
                prefix=".cccc-publish-", dir=str(destination.parent)
            )
            temp_path = Path(raw_temp_path)
        except OSError as error:
            raise PublishError(f"cannot create destination-side temporary file: {error}") from error

        with os.fdopen(source_fd, "rb", closefd=True) as source_stream:
            source_fd = -1
            with os.fdopen(temp_fd, "wb", closefd=True) as destination_stream:
                temp_fd = None
                shutil.copyfileobj(source_stream, destination_stream)
                destination_stream.flush()
                os.fsync(destination_stream.fileno())

        try:
            os.link(temp_path, destination)
            # The absent destination now names the fully fsynced payload. This is
            # the publication commit point; later temp cleanup cannot undo it.
            committed = True
        except FileExistsError as error:
            raise PublishError("destination appeared during publication") from error
        except OSError as error:
            raise PublishError(f"atomic hard-link publication is unavailable: {error}") from error
    finally:
        if source_fd >= 0:
            os.close(source_fd)
        if temp_fd is not None:
            os.close(temp_fd)
        if temp_path is not None:
            try:
                temp_path.unlink()
            except FileNotFoundError:
                pass
            except OSError as error:
                cleanup_error = error
        if cleanup_error is not None:
            if committed:
                print(
                    "cccc publish: warning: destination committed, but owned temporary "
                    f"file cleanup failed: {cleanup_error}",
                    file=sys.stderr,
                )
            elif sys.exc_info()[0] is None:
                raise PublishError(f"cannot remove owned temporary file: {cleanup_error}")


def main(argv: Sequence[str] | None = None) -> int:
    arguments = list(sys.argv[1:] if argv is None else argv)
    if len(arguments) != 2:
        print("usage: publish-no-clobber.py SOURCE DESTINATION", file=sys.stderr)
        return USAGE_ERROR

    try:
        publish(Path(arguments[0]), Path(arguments[1]))
    except (PublishError, OSError) as error:
        print(f"cccc publish: {error}", file=sys.stderr)
        return PUBLISH_ERROR
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
