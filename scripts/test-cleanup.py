#!/usr/bin/env python3
"""Delete only a leased, freshly-created test directory, using directory FDs.

lease DIR records its identity while empty. clean DIR LEASE first validates and
plans every entry, then rechecks each identity before unlink/rmdir. --dry-run
prints the same resolved target and plan summary without deleting anything.
"""
import base64
import json
import os
from pathlib import Path
import re
import secrets
import stat
import sys
import tempfile

MARKER = ".mymole-test-lease"
FLAGS = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC


def require(condition, message):
    if not condition:
        raise ValueError(message)


def fingerprint(value):
    return [value.st_dev, value.st_ino, value.st_uid, value.st_mode]


def location(value):
    path = Path(os.path.abspath(value))
    require(str(path) == value, "target must be an absolute normalized path")
    parent = path.parent.resolve(strict=True)
    temporary = Path(tempfile.gettempdir()).resolve()
    require(parent == temporary or parent == Path("/private/tmp") or parent == Path("/tmp"), "target is not directly inside a temporary directory")
    require(re.fullmatch(r"mymole-[A-Za-z0-9_-]+", path.name) is not None, "target lacks the owned test prefix")
    require(not str(parent).startswith("/Users/"), "home folders are never cleanup roots")
    return parent, path.name


def lease(value):
    parent, name = location(value)
    with_fd = os.open(parent, FLAGS)
    try:
        fd = os.open(name, FLAGS, dir_fd=with_fd)
        try:
            info = os.fstat(fd)
            require(info.st_uid == os.getuid() and info.st_mode & 0o777 == 0o700, "test directory must be private and owned by this user")
            require(not os.listdir(fd), "a lease can be issued only while the directory is empty")
            record = {"identity": fingerprint(info), "nonce": secrets.token_hex(32)}
            encoded = json.dumps(record, sort_keys=True).encode()
            marker = os.open(MARKER, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600, dir_fd=fd)
            with os.fdopen(marker, "wb") as stream:
                stream.write(encoded)
            return base64.urlsafe_b64encode(encoded).decode()
        finally:
            os.close(fd)
    finally:
        os.close(with_fd)


def plan(fd, device):
    entries = []
    for name in sorted(os.listdir(fd)):
        info = os.stat(name, dir_fd=fd, follow_symlinks=False)
        require(info.st_dev == device and info.st_uid == os.getuid(), "foreign device or owner in cleanup tree")
        require(stat.S_ISDIR(info.st_mode) or stat.S_ISREG(info.st_mode) or stat.S_ISLNK(info.st_mode), "unexpected special file in cleanup tree")
        children = None
        if stat.S_ISDIR(info.st_mode):
            child = os.open(name, FLAGS, dir_fd=fd)
            try:
                require(fingerprint(os.fstat(child)) == fingerprint(info), "directory changed during preflight")
                children = plan(child, device)
            finally:
                os.close(child)
        entries.append((name, fingerprint(info), children))
    return entries


def execute(fd, entries):
    for name, identity, children in entries:
        require(fingerprint(os.stat(name, dir_fd=fd, follow_symlinks=False)) == identity, "entry changed after preflight")
        if children is None:
            os.unlink(name, dir_fd=fd)  # A symlink itself, never its destination.
        else:
            child = os.open(name, FLAGS, dir_fd=fd)
            try:
                require(fingerprint(os.fstat(child)) == identity, "directory was replaced")
                execute(child, children)
            finally:
                os.close(child)
            require(fingerprint(os.stat(name, dir_fd=fd, follow_symlinks=False)) == identity, "directory changed before removal")
            os.rmdir(name, dir_fd=fd)


def clean(value, token, dry_run=False):
    parent, name = location(value)
    record = json.loads(base64.urlsafe_b64decode(token))
    parent_fd = os.open(parent, FLAGS)
    try:
        fd = os.open(name, FLAGS, dir_fd=parent_fd)
        try:
            info = os.fstat(fd)
            require(fingerprint(info) == record["identity"], "cleanup root no longer matches its lease")
            require(info.st_uid == os.getuid() and info.st_mode & 0o777 == 0o700, "cleanup root is no longer private")
            marker = os.open(MARKER, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=fd)
            with os.fdopen(marker, "rb") as stream:
                marker_info = os.fstat(stream.fileno())
                require(stat.S_ISREG(marker_info.st_mode) and marker_info.st_uid == os.getuid() and marker_info.st_size <= 4096, "invalid lease marker")
                require(json.loads(stream.read()) == record, "lease marker doesn't match")
            entries = plan(fd, info.st_dev)
            def count(items):
                return sum(1 + (count(child) if child is not None else 0) for _, _, child in items)
            print(f"Verified test cleanup: target={str(parent / name)!r}, entries={count(entries)}, dry_run={dry_run}", file=sys.stderr)
            if dry_run:
                return
            execute(fd, entries)
            require(not os.listdir(fd), "unplanned entries appeared during cleanup")
            require(fingerprint(os.stat(name, dir_fd=parent_fd, follow_symlinks=False)) == record["identity"], "root changed before final removal")
            os.rmdir(name, dir_fd=parent_fd)
        finally:
            os.close(fd)
    finally:
        os.close(parent_fd)


if __name__ == "__main__":
    try:
        args = sys.argv[1:]
        if len(args) == 2 and args[0] == "lease":
            print(lease(args[1]))
        elif len(args) in (3, 4) and args[0] == "clean" and (len(args) == 3 or args[3] == "--dry-run"):
            clean(args[1], args[2], dry_run=len(args) == 4)
        else:
            raise ValueError("usage: test-cleanup.py lease DIR | clean DIR LEASE [--dry-run]")
    except (ValueError, OSError, KeyError, TypeError) as error:
        print(f"Test cleanup refused: {error}", file=sys.stderr)
        sys.exit(1)
