#!/usr/bin/env python3
"""Preload a memcached instance with a fixed number of key/value records.

Ported from an internal AWS benchmarking framework's memcached workload. Uses only the Python standard
library so it runs anywhere the repro framework does, with no pip installs.

Usage: load_memcached.py <ip> <port> <records> <key_prefix> <value_size>

Keys are "<key_prefix><i>" for i in [1, records]; values are random
alphanumeric strings of the requested size. Commands are batched over one
connection, and every batch's replies are read back and checked, so a server
that refuses writes (memcached runs with evictions disabled, so an oversized
dataset makes it reject SETs) fails the preload loudly instead of leaving a
partly-filled cache that later measures as a valid result. The final item count
is verified against `stats` before exiting.

Duplicated verbatim in the `memcached` (memtier) workload -- the repro framework
keeps each workload self-contained under its own `files/`, so these are copies,
not symlinks. Keep them in sync when editing either one.
"""

import random
import socket
import string
import sys

BATCH_BYTES = 1024 * 1024


def main():
    if len(sys.argv) != 6:
        print(__doc__, file=sys.stderr)
        return 2

    ip = sys.argv[1]
    port = int(sys.argv[2])
    records = int(sys.argv[3])
    key_prefix = sys.argv[4]
    value_size = int(sys.argv[5])

    # A zero/negative record count would flush the cache and then report success
    # (the curr_items check below compares `< records`, and 0 < 0 is false), so
    # the whole measurement would run against an empty server.
    if records < 1:
        print("records must be at least 1, got {}".format(records), file=sys.stderr)
        return 2
    if value_size < 1:
        print("value_size must be at least 1, got {}".format(value_size), file=sys.stderr)
        return 2

    alphabet = string.ascii_letters + string.digits
    s = socket.socket()
    s.connect((ip, port))
    reply_buf = b""

    def _read_lines(count):
        """Read until `count` CRLF-terminated reply lines are buffered."""
        nonlocal reply_buf
        while reply_buf.count(b"\r\n") < count:
            chunk = s.recv(65536)
            if not chunk:
                raise RuntimeError(
                    "memcached closed the connection after {} of {} replies".format(
                        reply_buf.count(b"\r\n"), count))
            reply_buf += chunk
        lines = reply_buf.split(b"\r\n")
        reply_buf = lines.pop()
        return lines[:count]

    def _send(expected):
        """Send the queued batch and verify every reply. `expected` = command count."""
        nonlocal cmds, current_len
        if current_len == 0:
            return
        s.sendall(b"".join(cmds))
        # A short read here would leave replies unconsumed and the tail of the
        # dataset silently unstored, so drain exactly one reply per command.
        for line in _read_lines(expected):
            if line not in (b"STORED", b"OK"):
                raise RuntimeError("memcached rejected a write: {!r}".format(line))
        cmds = []
        current_len = 0

    cmds = []
    current_len = 0

    # Drop any existing keys so a re-run starts from a known state.
    cmds.append(b"flush_all\r\n")
    current_len += len(cmds[-1])
    _send(1)

    pending = 0
    for i in range(1, records + 1):
        key = "{}{}".format(key_prefix, i)
        value = "".join(random.choices(alphabet, k=value_size))
        cmd = "set {} 0 0 {}\r\n{}\r\n".format(key, len(value), value).encode("ascii")
        cmds.append(cmd)
        current_len += len(cmd)
        pending += 1
        # Flush once the batch is large enough to keep memory bounded.
        if current_len >= BATCH_BYTES:
            _send(pending)
            pending = 0

    _send(pending)

    # Confirm the server holds what we think it does; a mismatch means the
    # dataset does not fit (raise MEMCACHED_MEMORY_LIMIT) and every later
    # measurement would be against a partly-empty cache.
    s.sendall(b"stats\r\n")
    stats, curr_items = b"", None
    while b"END\r\n" not in stats:
        chunk = s.recv(65536)
        if not chunk:
            break
        stats += chunk
    for line in stats.split(b"\r\n"):
        if line.startswith(b"STAT curr_items "):
            curr_items = int(line.split()[2])
            break
    s.close()

    if curr_items is None:
        print("Warning: could not read curr_items from stats; preload unverified",
              file=sys.stderr)
    elif curr_items != records:
        # Both directions matter. Fewer means the dataset did not fit (evictions
        # are disabled, so the server refused writes) and the measurement would
        # run against a partly-empty cache. More means keys from a previous run or
        # another client are still resident, so the working set is not the one
        # this run intends to measure.
        print("Preload mismatch: memcached holds {} items, expected exactly {}. "
              "Fewer means the dataset does not fit under the server's memory "
              "limit (evictions are disabled) -- raise MEMCACHED_MEMORY_LIMIT or "
              "lower MEMCACHED_RECORDS. More means the cache still holds keys "
              "from another run -- restart memcached before "
              "preloading.".format(curr_items, records), file=sys.stderr)
        return 1

    print("Loaded {} records (prefix '{}', {}B values) into {}:{}".format(
        records, key_prefix, value_size, ip, port))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (RuntimeError, OSError) as exc:
        # OSError covers the socket errors a dying server produces
        # (ConnectionResetError, BrokenPipeError); report them as a preload
        # failure rather than leaking a traceback at the operator.
        print("Preload failed: {}".format(exc), file=sys.stderr)
        sys.exit(1)
