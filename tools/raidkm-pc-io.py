#!/usr/bin/env python3
# raidkm-pc-io.py — self-describing block workload and its oracle, for the
# power-cut (raidkm-test-powercut.sh) and fault-sequence (raidkm-test-chaos.sh)
# harnesses.
#
# Every 512-byte sector the workload writes describes itself:
#
#     0  8  magic "RKPCIO01"
#     8  8  sector number on the device
#    16  8  generation (per 4 KiB block, starts at 1; 0 = never written)
#    24  484 payload, shake128(sector, generation)
#   508  4  blake2b-32 of bytes 0..507 (not crc32: see payload())
#
# so a read can be judged without knowing what was written last: a sector is
# either all zero (never written), or intact with the right sector number and a
# generation inside the window the oracle allows.  That window is what makes
# the check an honest crash oracle instead of "every byte as written":
#
#   lower  the generation last made DURABLE — written, then fdatasync()ed and
#          the fdatasync returned — before the crash.  Reading anything older is
#          a lost acknowledged write: always a failure.
#   upper  the last generation ever issued.  Anything between the two may
#          legitimately be there after a crash (issued, not yet durable), sector
#          by sector: a 4 KiB write that did not become durable may be torn.
#
# Each worker thread owns a disjoint slice of the blocks, so one block has one
# writer and its generations are totally ordered.  After every --sync-every
# writes the thread fdatasync()s the device and then appends "block gen" for
# everything it wrote since the last sync to --journal (one O_APPEND write per
# sync).  A harness that stops the world, reads the journal's length, and later
# hands that length to `verify --journal-bytes` gets a lower bound that is
# exactly "durable at the cut" (or less: the journal line is written after the
# fdatasync returns, so it can only under-claim).
#
# Writes mix single 4 KiB blocks at random with bursts of consecutive blocks
# (up to --burst), so full rows and partial rows (read-modify-write) both occur.
#
# Discards (--discard F: that fraction of the operations): BLKDISCARD of 1 to
# --discard-rows whole rows (--discard-align blocks each) inside the thread's
# slice.  A discarded block reads back as zeroes or as what it held, so the
# oracle also takes zero for a block discarded after its durable generation
# was written.  "Discarded after" is known from --dlog: before each discard
# the thread appends "block gen" for every block of it (gen = the block's
# last issued generation, the discard comes after it).  The record goes out
# BEFORE the discard, so a prefix of --dlog taken at a cut names every
# discard that can have reached the device by then (and maybe one or two
# that had not yet: a weaker oracle for those blocks, never a false fail).
# A discard never moves the durable bound: an acknowledged write that a
# later discard covered may still read back.
#
#   run      the workload; --seconds or until SIGTERM/SIGINT; on exit writes the
#            per-block last-issued generations to --gens (the upper bound).
#            --live-verify N adds N reader threads checking every read against
#            the in-memory window (for fault sequences on a live array).
#   verify   read every block and judge it against the journal prefix and gens.
#   replay   write a dm-log-writes log up to a mark onto a zeroed device.
#   find     every logged write that carried one array sector's image.
#   order    images logged older-after-newer at one member byte: on a
#            log-writes-ord (version 2) log, md writing stale data.
#
# Exit status: 0 clean, 1 verification failure(s), 2 usage / I/O setup error.

import argparse
import fcntl
import hashlib
import mmap
import os
import random
import signal
import struct
import sys
import threading
import time

SECT = 512
BLKDISCARD = 0x1277
BLK = 4096
SPB = BLK // SECT
MAGIC = b"RKPCIO01"
HDR = struct.Struct("<8sQQ")


# Payload and check value are cryptographic hashes ON PURPOSE.  A degraded
# read of a stale stripe returns an XOR (or GF combination) of real images, and
# crc32 + any payload built from crc32 are GF(2)-affine: the XOR of three valid
# images of one sector is itself a "valid" image with gen = a^b^c.  The first
# version of this format did exactly that -- a write-hole reconstruction came
# back as a never-issued generation.  Non-linear hashes make every mixture
# read as garbage.
def payload(sector, gen):
    return hashlib.shake_128(struct.pack("<QQ", sector, gen)).digest(484)


def check(body):
    return hashlib.blake2b(body, digest_size=4).digest()


def make_block(block, gen, buf, off=0):
    for i in range(SPB):
        s = block * SPB + i
        body = HDR.pack(MAGIC, s, gen) + payload(s, gen)
        buf[off + i * SECT: off + i * SECT + 508] = body
        buf[off + i * SECT + 508: off + (i + 1) * SECT] = check(body)


ZERO = bytes(SECT)


def judge_sector(raw, sector, lo, hi, disc=-1):
    """Return None if acceptable, else a short reason.  disc: the issued
    generation when the block was last discarded (-1: never)."""
    if raw == ZERO:
        return None if lo == 0 or disc >= lo else "zero (durable gen %d lost)" % lo
    if check(raw[:508]) != raw[508:]:
        return "garbage (check)"
    magic, s, gen = HDR.unpack_from(raw)
    if magic != MAGIC:
        return "garbage (magic)"
    if s != sector:
        return "misplaced (holds sector %d gen %d)" % (s, gen)
    if raw[24:508] != payload(s, gen):
        return "garbage (payload)"
    if gen < lo:
        return "stale gen %d < durable %d" % (gen, lo)
    if hi is not None and gen > hi:
        return "future gen %d > issued %d" % (gen, hi)
    return None


def open_dev(path, write):
    flags = (os.O_RDWR if write else os.O_RDONLY) | os.O_DIRECT
    return os.open(path, flags)


# --------------------------------------------------------------------- run
class State:
    def __init__(self, nblocks):
        self.issued = [0] * nblocks      # last generation submitted
        self.durable = [0] * nblocks     # last generation fdatasync()ed
        self.disc = [-1] * nblocks       # issued generation at the last discard
        self.stop = threading.Event()
        self.errors = []
        self.lock = threading.Lock()
        self.writes = 0
        self.syncs = 0
        self.reads = 0
        self.discards = 0

    def err(self, msg):
        with self.lock:
            self.errors.append(msg)
            print("VERIFY-FAIL " + msg, file=sys.stderr, flush=True)


def writer(a, st, tid, jfd, dfd):
    rng = random.Random(a.seed * 1000 + tid)
    lo = a.blocks * tid // a.threads
    hi = a.blocks * (tid + 1) // a.threads
    fd = open_dev(a.dev, True)
    buf = mmap.mmap(-1, BLK * a.burst)
    pending = {}
    nw = 0
    al = a.discard_align
    r0, r1 = -(-lo // al) if al else 0, hi // al if al else 0	# whole rows inside
    try:
        while not st.stop.is_set():
            if a.discard and r1 > r0 and rng.random() < a.discard:
                n = rng.randint(1, min(a.discard_rows, r1 - r0))
                b0 = rng.randrange(r0, r1 - n + 1) * al
                nb = n * al
                for b in range(b0, b0 + nb):
                    st.disc[b] = st.issued[b]
                if dfd is not None:
                    os.write(dfd, "".join("%d %d\n" % (b, st.issued[b])
                                          for b in range(b0, b0 + nb)).encode())
                try:
                    fcntl.ioctl(fd, BLKDISCARD, struct.pack("QQ", b0 * BLK, nb * BLK))
                except OSError as e:
                    st.err("discard blocks %d+%d: %s" % (b0, nb, e))
                    if a.stop_on_error:
                        st.stop.set()
                    continue
                with st.lock:
                    st.discards += 1
                continue
            if a.burst > 1 and rng.random() < 0.3:
                n = rng.randint(2, min(a.burst, hi - lo))
                b0 = rng.randrange(lo, hi - n + 1)
            else:
                n, b0 = 1, rng.randrange(lo, hi)
            for i in range(n):
                g = st.issued[b0 + i] + 1
                st.issued[b0 + i] = g
                make_block(b0 + i, g, buf, i * BLK)
                pending[b0 + i] = g
            try:
                os.pwritev(fd, [memoryview(buf)[:n * BLK]], b0 * BLK)
            except OSError as e:
                # a write error on a live array is a finding in its own
                # right (md should have hidden the member failure)
                st.err("write blocks %d+%d: %s" % (b0, n, e))
                if a.stop_on_error:
                    st.stop.set()
                continue
            nw += n
            with st.lock:
                st.writes += n
            if nw >= a.sync_every:
                nw = 0
                try:
                    os.fdatasync(fd)
                except OSError as e:
                    st.err("fdatasync: %s" % e)
                    continue
                for b, g in pending.items():
                    if g > st.durable[b]:
                        st.durable[b] = g
                if jfd is not None:
                    os.write(jfd, "".join("%d %d\n" % bg
                                          for bg in pending.items()).encode())
                pending.clear()
                with st.lock:
                    st.syncs += 1
            if a.pause_ms:
                time.sleep(rng.random() * a.pause_ms / 1000.0)
    finally:
        os.close(fd)


def reader(a, st, tid):
    rng = random.Random(a.seed * 1000 + 500 + tid)
    fd = open_dev(a.dev, False)
    buf = mmap.mmap(-1, BLK)
    try:
        while not st.stop.is_set():
            b = rng.randrange(a.blocks)
            lo = st.durable[b]
            try:
                os.preadv(fd, [buf], b * BLK)
            except OSError as e:
                st.err("read block %d: %s" % (b, e))
                if a.stop_on_error:
                    st.stop.set()
                continue
            hi = st.issued[b]
            for i in range(SPB):
                r = judge_sector(bytes(buf[i * SECT:(i + 1) * SECT]),
                                 b * SPB + i, lo, hi, st.disc[b])
                if r:
                    st.err("live block %d sector %d: %s" % (b, b * SPB + i, r))
                    if a.stop_on_error:
                        st.stop.set()
                    break
            with st.lock:
                st.reads += 1
    finally:
        os.close(fd)


def cmd_run(a):
    st = State(a.blocks)
    if a.resume_gens:
        with open(a.resume_gens) as f:
            for line in f:
                b, g = map(int, line.split())
                st.issued[b] = st.durable[b] = g
    jfd = None
    if a.journal:
        jfd = os.open(a.journal, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o644)
    for s in (signal.SIGTERM, signal.SIGINT):
        signal.signal(s, lambda *_: st.stop.set())
    dfd = None
    if a.dlog:
        dfd = os.open(a.dlog, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o644)
    th = [threading.Thread(target=writer, args=(a, st, t, jfd, dfd), daemon=True)
          for t in range(a.threads)]
    th += [threading.Thread(target=reader, args=(a, st, t), daemon=True)
           for t in range(a.live_verify)]
    for t in th:
        t.start()
    if a.ready:
        open(a.ready, "w").close()
    t0 = time.time()
    last = t0
    while not st.stop.is_set():
        st.stop.wait(0.2)
        if a.seconds and time.time() - t0 >= a.seconds:
            st.stop.set()
        if a.progress and time.time() - last >= a.progress:
            last = time.time()
            print("progress %.0fs writes %d syncs %d discards %d reads %d errors %d" %
                  (last - t0, st.writes, st.syncs, st.discards, st.reads,
                   len(st.errors)),
                  flush=True)
    for t in th:
        t.join()
    if a.gens:
        with open(a.gens, "w") as f:
            f.writelines("%d %d\n" % (b, g)
                         for b, g in enumerate(st.issued) if g)
    print("run done: writes %d syncs %d discards %d reads %d errors %d" %
          (st.writes, st.syncs, st.discards, st.reads, len(st.errors)),
          flush=True)
    return 1 if st.errors else 0


# ------------------------------------------------------------------ verify
def read_blocks(fd, buf, b0, n):
    """A chunk read failed or came back short (EIO from a block md cannot
    rebuild, a CRC mismatch on a --checksum array): read it again block by
    block, so the blocks that do read are still judged.  Returns {index in
    chunk: reason} for the blocks that cannot be read."""
    bad = {}
    for j in range(n):
        try:
            got = os.preadv(fd, [memoryview(buf)[j * BLK:(j + 1) * BLK]],
                            (b0 + j) * BLK)
            if got != BLK:
                bad[j] = "short read %d" % got
        except OSError as e:
            bad[j] = os.strerror(e.errno) if e.errno else str(e)
    return bad


def cmd_verify(a):
    lo = [0] * a.blocks
    if a.journal:
        with open(a.journal, "rb") as f:
            data = f.read() if a.journal_bytes is None else f.read(a.journal_bytes)
        data = data[:data.rfind(b"\n") + 1]
        for line in data.splitlines():
            b, g = map(int, line.split())
            if b < a.blocks and g > lo[b]:
                lo[b] = g
    disc = [-1] * a.blocks
    ndisc = 0
    if a.dlog:
        with open(a.dlog, "rb") as f:
            data = f.read() if a.dlog_bytes is None else f.read(a.dlog_bytes)
        data = data[:data.rfind(b"\n") + 1]
        for line in data.splitlines():
            b, g = map(int, line.split())
            if b < a.blocks and g > disc[b]:
                disc[b] = g
        ndisc = sum(1 for b in range(a.blocks) if disc[b] >= lo[b] and lo[b])
    hi = None
    if a.gens:
        hi = [0] * a.blocks
        with open(a.gens) as f:
            for line in f:
                b, g = map(int, line.split())
                if b < a.blocks:
                    hi[b] = g
    fd = open_dev(a.dev, False)
    size = os.lseek(fd, 0, os.SEEK_END)
    if size < a.blocks * BLK:	# a setup error, not data loss
        print("%s holds %d bytes, --blocks %d needs %d" %
              (a.dev, size, a.blocks, a.blocks * BLK), file=sys.stderr)
        os.close(fd)
        return 2
    chunk = 256
    buf = mmap.mmap(-1, BLK * chunk)
    bad = {}
    nbad = 0
    zdisc = 0	# durable blocks that read zero because a discard came after
    durable = sum(1 for g in lo if g)
    try:
        for b0 in range(0, a.blocks, chunk):
            n = min(chunk, a.blocks - b0)
            mv = memoryview(buf)[:n * BLK]
            try:
                got = os.preadv(fd, [mv], b0 * BLK)
            except OSError:
                got = -1
            # A short read is how an O_DIRECT error can show up too:
            # either way, read the chunk again block by block.
            unreadable = {} if got == n * BLK else read_blocks(fd, buf, b0, n)
            for j in range(n):
                b = b0 + j
                if j in unreadable:
                    if nbad < a.show:
                        print("  bad block %d sectors %d-%d: unreadable (%s)" %
                              (b, b * SPB, b * SPB + SPB - 1, unreadable[j]))
                    nbad += SPB
                    bad["unreadable"] = bad.get("unreadable", 0) + SPB
                    continue
                h = None if hi is None else hi[b]
                if lo[b] and buf[j * BLK:(j + 1) * BLK] == ZERO * SPB:
                    zdisc += 1
                for i in range(SPB):
                    off = j * BLK + i * SECT
                    r = judge_sector(bytes(buf[off:off + SECT]),
                                     b * SPB + i, lo[b], h, disc[b])
                    if r:
                        nbad += 1
                        kind = r.split(" (")[0].split(" gen")[0]
                        bad[kind] = bad.get(kind, 0) + 1
                        if nbad <= a.show:
                            print("  bad block %d sector %d: %s" %
                                  (b, b * SPB + i, r))
    finally:
        os.close(fd)
    if nbad:
        print("verify FAIL: %d bad sectors %s (%d blocks durable)" %
              (nbad, bad, durable))
        return 1
    print("verify ok: %d blocks, %d with a durable generation%s" %
          (a.blocks, durable,
           ", %d of them discarded after it (%d read zero)" % (ndisc, zdisc)
           if a.dlog else ""))
    return 0


# ------------------------------------------------------------------ replay
# A dm-log-writes log (the format xfstests' src/log-writes reads): a super
# sector, then per entry a header sector {sector, nr_sectors, flags, data_len}
# followed by nr_sectors of data.
#
# Version 1 (stock dm-log-writes): a plain write is logged only when a later
# FLUSH completes, together with the writes that had completed when that flush
# was mapped -- so a FLUSH entry covers every write logged before it.  But two
# flushes can complete in the other order than they were mapped (a submitter
# waiting for a request tag between the two), and then a group of writes that
# completed LATER is logged first: two writes to one sector come out swapped,
# a state no device can produce.  The harness once read that as data loss.
#
# Version 2 (tools/dm-log-writes-ord, target log-writes-ord): every write is
# logged when it completes, so the log is the true completion order; a flush
# logs FLUSH_START (data: its 64-bit id) when it is mapped and FLUSH (same id)
# when it completes.  The writes logged before a flush's FLUSH_START are the
# ones it made durable, once its FLUSH is in the log.  An entry that completed
# with an error (LW_ERROR) is skipped: a failed write left nothing we can
# name, a failed flush made nothing durable.
#
# replay can only replay a prefix, which after a cut throws away FUA writes
# too -- a crash no real drive produces (the old crash harness's caveat).  This
# replays the state a volatile write cache can really leave behind at a mark:
#
#   mark   every write completed before the mark (a write-through device);
#          version 1: only those a flush had logged by then
#   flush  only what the flushes completed before the mark covered, plus FUA
#          writes
#   cache  like flush, but each write after that survives at random (the
#          cache wrote some back, in any order) -- seeded
LW_MAGIC = 0x6a736677736872
LW_FLUSH, LW_FUA, LW_DISCARD, LW_MARK = 1, 2, 4, 8
LW_FLUSH_START, LW_ERROR = 32, 64
LW_ENT = struct.Struct("<QQQQ")


class LogEntry:
    __slots__ = ("idx", "off", "size", "flags", "mark", "fid", "dpos")

    def __init__(self, idx, off, size, flags, mark, fid, dpos):
        self.idx, self.off, self.size, self.flags = idx, off, size, flags
        self.mark, self.fid, self.dpos = mark, fid, dpos


def log_open(f):
    """-> (version, entry iterator).  off/size in bytes, size 0 = no data."""
    sup = f.read(28)
    magic, ver, nr, ssz = struct.unpack("<QQQI", sup)
    if magic != LW_MAGIC or ver not in (1, 2):
        raise SystemExit("not a dm-log-writes log (magic %#x ver %d)" % (magic, ver))

    def entries():
        pos = ssz
        for i in range(nr):
            f.seek(pos)
            hdr = f.read(ssz)
            sector, nsec, flags, dlen = LW_ENT.unpack_from(hdr)
            data = hdr[32:32 + dlen]
            mark = data.decode(errors="replace") if flags & LW_MARK else None
            fid = (struct.unpack_from("<Q", data)[0]
                   if ver == 2 and flags & (LW_FLUSH | LW_FLUSH_START) and
                   dlen == 8 else None)
            size = 0 if flags & LW_DISCARD else nsec * ssz
            yield LogEntry(i, sector * ssz, nsec * ssz, flags, mark, fid,
                           pos + ssz)
            pos += ssz + size
    return ver, entries()


def durable_bound(ver, ents):
    """Entries before this index are durable (flush/cache modes)."""
    if ver == 1:
        return 1 + max((k for k, e in enumerate(ents) if e.flags & LW_FLUSH),
                       default=-1)
    start = {}
    bound = 0
    for k, e in enumerate(ents):
        if e.flags & LW_ERROR:
            continue
        if e.flags & LW_FLUSH_START:
            start[e.fid] = k
        elif e.flags & LW_FLUSH and e.fid in start:
            bound = max(bound, start[e.fid])
    return bound


def cmd_replay(a):
    rng = random.Random(a.seed)
    with open(a.log, "rb") as f:
        ver, it = log_open(f)
        ents = []
        found = False
        for e in it:
            if e.mark == a.mark:
                found = True
                break
            ents.append(e)
        if not found:
            raise SystemExit("mark %r not in %s" % (a.mark, a.log))
        bound = durable_bound(ver, ents)
        out = os.open(a.dev, os.O_WRONLY)
        kept = dropped = 0
        try:
            for k, e in enumerate(ents):
                if e.mark is not None or e.size == 0 or e.flags & LW_ERROR:
                    continue
                if a.mode != "mark" and k >= bound and not e.flags & LW_FUA:
                    if a.mode == "flush" or rng.random() < 0.5:
                        dropped += 1
                        continue
                if e.flags & LW_DISCARD:
                    os.pwrite(out, bytes(e.size), e.off)
                else:
                    f.seek(e.dpos)
                    os.pwrite(out, f.read(e.size), e.off)
                kept += 1
            os.fsync(out)
        finally:
            os.close(out)
    print("replay %s -> %s to %s (%s, log v%d): %d writes, %d unflushed dropped" %
          (a.log, a.dev, a.mark, a.mode, ver, kept, dropped))
    return 0


def log_images(f, e):
    """(member byte, array sector, gen, check ok) of each self-describing
    sector a logged write carried."""
    f.seek(e.dpos)
    data = f.read(e.size)
    for o in range(0, e.size, SECT):
        raw = data[o:o + SECT]
        if raw[:8] != MAGIC:
            continue
        _, s, gen = HDR.unpack_from(raw)
        yield e.off + o, s, gen, check(raw[:508]) == raw[508:]


def cmd_find(a):
    """Every logged write that carried <sector>'s self-describing image."""
    for log in a.log:
        with open(log, "rb") as f:
            _, it = log_open(f)
            for e in it:
                if e.mark is not None:
                    print("%s #%d mark %s" % (log, e.idx, e.mark))
                    continue
                if e.size == 0 or e.flags & LW_DISCARD:
                    continue
                for mb, s, gen, ok in log_images(f, e):
                    if s == a.sector:
                        print("%s #%d member byte %d: gen %d flags %#x%s" %
                              (log, e.idx, mb, gen, e.flags,
                               "" if ok else " BAD-CHECK"))
    return 0


def cmd_order(a):
    """Writes logged out of order: a sector's image whose generation is older
    than the one logged before it at the same member byte.  The workload never
    has two writes to one block in flight, so on a version-2 log (completion
    order) each one is md writing stale data; on a version-1 log it may be the
    flush reordering described above.  Parity sectors are skipped: an XOR of
    three images starts with the magic too, but its check bytes do not hold."""
    bad = 0
    for log in a.log:
        with open(log, "rb") as f:
            ver, it = log_open(f)
            last = {}
            n = 0
            mark = None
            for e in it:
                n += 1
                if e.mark is not None:
                    mark = e.mark
                    continue
                if e.size == 0 or e.flags & (LW_DISCARD | LW_ERROR):
                    continue
                for mb, s, gen, ok in log_images(f, e):
                    if not ok:
                        continue
                    p = last.get(mb)
                    if p and p[0] == s and gen < p[1]:
                        bad += 1
                        print("%s (v%d) #%d member byte %d sector %d: gen %d "
                              "after gen %d at #%d%s" %
                              (log, ver, e.idx, mb, s, gen, p[1], p[2],
                               " (after mark %s)" % mark if mark else ""))
                    last[mb] = (s, gen, e.idx)
            print("%s (v%d): %d entries" % (log, ver, n))
    print("order: %d out-of-order writes" % bad)
    return 1 if bad else 0


def main():
    p = argparse.ArgumentParser(description="self-describing block workload, crash replayer and oracle")
    sub = p.add_subparsers(dest="cmd", required=True)
    r = sub.add_parser("run")
    v = sub.add_parser("verify")
    rp = sub.add_parser("replay")
    rp.add_argument("--log", required=True)
    rp.add_argument("--dev", required=True, help="target, pre-zeroed")
    rp.add_argument("--mark", required=True)
    rp.add_argument("--mode", choices=("mark", "flush", "cache"), default="mark")
    rp.add_argument("--seed", type=int, default=1)
    fd_ = sub.add_parser("find")
    fd_.add_argument("--sector", type=int, required=True)
    fd_.add_argument("log", nargs="+")
    od = sub.add_parser("order")
    od.add_argument("log", nargs="+")
    for q in (r, v):
        q.add_argument("--dev", required=True)
        q.add_argument("--blocks", type=int, required=True,
                       help="4 KiB blocks used from the start of --dev")
        q.add_argument("--journal", help="durable journal file")
        q.add_argument("--gens", help="last-issued generations file")
        q.add_argument("--dlog", help="discard log (block gen per discarded block)")
    r.add_argument("--threads", type=int, default=8)
    r.add_argument("--live-verify", type=int, default=0, metavar="N")
    r.add_argument("--sync-every", type=int, default=16)
    r.add_argument("--burst", type=int, default=64)
    r.add_argument("--pause-ms", type=float, default=0)
    r.add_argument("--seconds", type=float, default=0)
    r.add_argument("--seed", type=int, default=1)
    r.add_argument("--progress", type=float, default=0)
    r.add_argument("--ready", help="touch this file once the threads run")
    r.add_argument("--resume-gens",
                   help="continue from a gens file (all of it durable)")
    r.add_argument("--stop-on-error", action="store_true")
    r.add_argument("--discard", type=float, default=0, metavar="F",
                   help="fraction of operations that are discards")
    r.add_argument("--discard-align", type=int, default=0, metavar="BLOCKS",
                   help="a row in 4 KiB blocks: discards are whole rows")
    r.add_argument("--discard-rows", type=int, default=4,
                   help="at most this many rows per discard")
    v.add_argument("--journal-bytes", type=int)
    v.add_argument("--dlog-bytes", type=int)
    v.add_argument("--show", type=int, default=20)
    a = p.parse_args()
    if a.cmd == "replay":
        sys.exit(cmd_replay(a))
    if a.cmd == "find":
        sys.exit(cmd_find(a))
    if a.cmd == "order":
        sys.exit(cmd_order(a))
    if a.cmd == "run":
        if a.threads < 1 or a.blocks < a.threads * max(a.burst, 1):
            p.error("--blocks must be >= threads * burst")
        if a.discard and a.discard_align < 1:
            p.error("--discard needs --discard-align (a row in blocks)")
        if not 0 <= a.discard <= 1 or a.discard_rows < 1:
            p.error("--discard is a fraction in [0, 1], --discard-rows >= 1")
        sys.exit(cmd_run(a))
    sys.exit(cmd_verify(a))


if __name__ == "__main__":
    main()
