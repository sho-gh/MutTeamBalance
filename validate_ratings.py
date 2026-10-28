#!/usr/bin/env python3
"""
validate_ratings.py - check and clean the TeamBalance ratings file before upload.

The game's ini reader cannot skip a hidden BOM or read UTF-16, and it silently
ignores lines it doesn't understand. This script is the safety net: it fixes
what can be fixed, refuses to produce a bad file, and adds three header lines
that let the mutator notice a partly-read file.

Usage:
  python validate_ratings.py INPUT OUTPUT [--previous LAST_GOOD.ini] [--min-entries 50] [--force]
  python validate_ratings.py INPUT --check-only        (report only, write nothing)

Run it as the last step of the script that builds the file, and upload OUTPUT
only if the exit code is 0.

Exit codes: 0 = OK (output written; any fixes are listed), 1 = file has errors
that can't be fixed (nothing written), 2 = sanity check failed, e.g. far fewer
entries than last time (nothing written; use --force to override).

What it fixes automatically:
  * UTF-8 BOM, UTF-16 encoding, non-ASCII characters (names are dropped)
  * line endings (always written as Windows CRLF)
  * upper-case GUIDs (written lower-case), Name= fields (removed)
  * wrong or missing [TeamBalance.TeamBalanceRatings] header
  * duplicate GUIDs (the first one is kept)
What it rejects: bad GUIDs, missing or non-numeric Elo/Mu/Sigma, too few entries.
"""
import argparse
import datetime
import os
import re
import sys

HEADER = "[TeamBalance.TeamBalanceRatings]"
FORMAT_VERSION = 1
GUID_RE = re.compile(r"^[0-9a-f]{32}$")
ENTRY_RE = re.compile(r"^\s*PlayerRatings\s*=\s*\((.*)\)\s*$", re.I)


def decode(data, notes):
    """Return text, noting any encoding fixes."""
    if data[:3] == b"\xef\xbb\xbf":
        data = data[3:]
        notes.append("FIXED: removed hidden UTF-8 BOM at the start of the file")
    if data[:2] in (b"\xff\xfe", b"\xfe\xff"):
        notes.append("FIXED: file was UTF-16; converted to ASCII")
        return data.decode("utf-16")
    if b"\x00" in data:
        notes.append("FIXED: file contained NUL bytes (probably UTF-16 without a BOM); converted")
        try:
            return data.decode("utf-16-le")
        except UnicodeDecodeError:
            return data.decode("latin-1").replace("\x00", "")
    try:
        text = data.decode("utf-8")
    except UnicodeDecodeError:
        notes.append("FIXED: file was not valid UTF-8; read as Latin-1")
        text = data.decode("latin-1")
    return text


def num(fields, key):
    m = re.search(r"\b" + key + r"\s*=\s*(-?\d+(?:\.\d+)?(?:[eE][-+]?\d+)?)", fields)
    return float(m.group(1)) if m else None


def fmt(x):
    return repr(round(x, 3))


def parse(text, notes, errors):
    text = text.replace("\r\n", "\n").replace("\r", "\n")
    lines = text.split("\n")
    header_seen = None
    entries, seen = [], {}
    n_upper = n_name = n_dup = 0
    for no, raw in enumerate(lines, 1):
        line = raw.strip()
        if not line:
            continue
        if line.startswith("["):
            if header_seen is None:
                header_seen = line
            else:
                errors.append("line %d: a second section header %r (expected only one)" % (no, line))
            continue
        m = ENTRY_RE.match(line)
        if not m:
            if re.match(r"^(FormatVersion|GeneratedAt|ExpectedCount)\s*=", line, re.I):
                continue                       # we rewrite these ourselves
            errors.append("line %d: not a PlayerRatings line: %.60s" % (no, line))
            continue
        fields = m.group(1)
        g = re.search(r'\bGuid\s*=\s*"([^"]*)"', fields)
        if not g:
            errors.append("line %d: no Guid=\"...\" found" % no)
            continue
        guid = g.group(1)
        if guid != guid.lower():
            n_upper += 1
        guid = guid.lower()
        if not GUID_RE.match(guid):
            errors.append("line %d: bad GUID %r (needs 32 hex characters)" % (no, guid))
            continue
        if re.search(r"\bName\s*=", fields):
            n_name += 1
        elo, mu, sg, rt = (num(fields, k) for k in ("Elo", "Mu", "Sigma", "Rating"))
        if None in (elo, mu, sg):
            errors.append("line %d: missing or non-numeric Elo/Mu/Sigma for %s" % (no, guid))
            continue
        if rt is None:
            rt = mu - 3.0 * sg
        if sg <= 0 or mu < 0 or mu > 60:
            notes.append("WARNING: odd numbers for %s (mu=%s sigma=%s)" % (guid, mu, sg))
        if abs(rt - (mu - 3.0 * sg)) > 0.5:
            notes.append("WARNING: Rating for %s is not Mu-3*Sigma (%s vs %s)" % (guid, rt, round(mu - 3 * sg, 2)))
        if guid in seen:
            n_dup += 1
            continue
        seen[guid] = True
        entries.append((guid, elo, mu, sg, rt))
    if header_seen is None:
        notes.append("FIXED: no section header found; added %s" % HEADER)
    elif header_seen != HEADER:
        notes.append("FIXED: header was %r; replaced with %s" % (header_seen, HEADER))
    if n_upper:
        notes.append("FIXED: %d upper-case GUIDs written in lower case" % n_upper)
    if n_name:
        notes.append("FIXED: removed Name= from %d entries (names break the game's ini reader)" % n_name)
    if n_dup:
        notes.append("FIXED: dropped %d duplicate GUIDs (first one kept)" % n_dup)
    return entries


def previous_count(path):
    try:
        with open(path, "rb") as f:
            return len(re.findall(rb"^PlayerRatings=", f.read(), re.M))
    except OSError:
        return None


def main():
    ap = argparse.ArgumentParser(description="Validate and clean the TeamBalance ratings file.")
    ap.add_argument("input")
    ap.add_argument("output", nargs="?")
    ap.add_argument("--previous", help="last known-good file, for a sanity check on the entry count")
    ap.add_argument("--min-entries", type=int, default=50)
    ap.add_argument("--check-only", action="store_true")
    ap.add_argument("--force", action="store_true", help="write the file even if the sanity check fails")
    a = ap.parse_args()
    if not a.check_only and not a.output:
        ap.error("OUTPUT is required unless --check-only is used")

    notes, errors = [], []
    with open(a.input, "rb") as f:
        data = f.read()
    text = decode(data, notes)
    if any(ord(c) > 127 for c in text):
        notes.append("FIXED: removed non-ASCII characters (the game's ini reader can't handle them)")
    entries = parse(text, notes, errors)

    print("Read %d bytes from %s: %d valid entries" % (len(data), a.input, len(entries)))
    for n in notes:
        print("  " + n)
    for e in errors[:20]:
        print("  ERROR: " + e)
    if len(errors) > 20:
        print("  ... and %d more errors" % (len(errors) - 20))

    if errors:
        print("RESULT: file has errors that can't be fixed automatically - nothing written")
        return 1

    sanity = []
    if len(entries) < a.min_entries:
        sanity.append("only %d entries (minimum %d)" % (len(entries), a.min_entries))
    if a.previous:
        prev = previous_count(a.previous)
        if prev and len(entries) < 0.8 * prev:
            sanity.append("%d entries, down from %d in the previous file" % (len(entries), prev))
    if sanity and not a.force:
        print("RESULT: sanity check failed (%s) - nothing written. Use --force to override." % "; ".join(sanity))
        return 2

    if a.check_only:
        clean = not notes
        print("RESULT: file is %s" % ("clean" if clean else "readable but would be changed by cleaning (see above)"))
        return 0 if clean else 1

    stamp = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%d %H:%M UTC")
    out = [HEADER,
           "FormatVersion=%d" % FORMAT_VERSION,
           "GeneratedAt=%s" % stamp,
           "ExpectedCount=%d" % len(entries)]
    for guid, elo, mu, sg, rt in entries:
        out.append('PlayerRatings=(Guid="%s",Elo=%s,Mu=%s,Sigma=%s,Rating=%s)' % (guid, fmt(elo), fmt(mu), fmt(sg), fmt(rt)))
    blob = ("\r\n".join(out) + "\r\n").encode("ascii")

    tmp = a.output + ".tmp"
    with open(tmp, "wb") as f:
        f.write(blob)
    with open(tmp, "rb") as f:                 # verify what we wrote
        back = f.read()
    ok = (back[:1] == b"[" and all(b < 128 for b in back)
          and len(re.findall(rb"^PlayerRatings=", back, re.M)) == len(entries))
    if not ok:
        os.remove(tmp)
        print("RESULT: self-check of the written file failed - nothing written")
        return 1
    os.replace(tmp, a.output)
    print("RESULT: wrote %s (%d entries, %d bytes, ASCII, CRLF, no BOM)" % (a.output, len(entries), len(blob)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
