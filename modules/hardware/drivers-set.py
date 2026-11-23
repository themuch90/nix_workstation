"""Replaces the graphics part of the my.hardware.drivers block in a host file
with a block detected on this PC (gpu-detect.sh drivers_block, on stdin).

Usage: drivers-set.py FILE --check   exit 0 = same graphics settings, 3 = different
       drivers-set.py FILE           writes the new block
Exit 2: no my.hardware.drivers block in FILE.

Graphics settings: enable, intel.*, amd.*, nvidia.* (sub-blocks included).
The other settings of the block (bluetooth, printers, scanners, allFirmware...)
are kept, with their comments.
"""
import re
import sys

GPU_KEY = re.compile(r"^\s*(enable|intel|amd|nvidia)\b")
KEEP_COMMENT = re.compile(r"^\s*#\s*(bluetooth|printers|scanners|allFirmware)\b")
START = re.compile(r"^\s*my\.hardware\.drivers\s*=\s*\{")


def code_of(line):
    return re.sub(r'"(\\.|[^"\\])*"', '""', line).split("#", 1)[0]


def block_end(lines, start):
    depth = 0
    for i in range(start, len(lines)):
        c = code_of(lines[i])
        depth += c.count("{") - c.count("}")
        if depth <= 0:
            return i
    raise SystemExit(f"unbalanced braces after line {start + 1}")


def split_block(lines, start, end):
    """(graphics lines, other lines) inside lines[start+1:end]."""
    gpu, other = [], []
    i = start + 1
    while i < end:
        line = lines[i]
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            if KEEP_COMMENT.match(line):
                other.append(line)
            i += 1
            continue
        target = gpu if GPU_KEY.match(line) else other
        c = code_of(line)
        j = block_end(lines, i) if c.count("{") > c.count("}") else i
        target.extend(lines[i:j + 1])
        i = j + 1
    return gpu, other


def norm(lines):
    out = []
    for line in lines:
        c = re.sub(r"\s+", " ", code_of(line)).strip()
        if c:
            out.append(c)
    return out


def main():
    if len(sys.argv) < 2:
        raise SystemExit(__doc__)
    path, check = sys.argv[1], "--check" in sys.argv[2:]
    with open(path) as f:
        lines = f.read().split("\n")
    start = next((i for i, l in enumerate(lines) if START.match(l)), None)
    if start is None:
        sys.exit(2)
    end = block_end(lines, start)
    if end == start:   # block written on one line: not handled
        sys.exit(2)
    new =[l for l in sys.stdin.read().split("\n") if l.strip()]
    new_start = next(i for i, l in enumerate(new) if START.match(l))
    new_end = block_end(new, new_start)
    new_gpu, _ = split_block(new, new_start, new_end)
    old_gpu, other = split_block(lines, start, end)
    if check:
        sys.exit(0 if norm(old_gpu) == norm(new_gpu) else 3)
    # same indentation as the existing block
    old_ind = re.match(r"\s*", lines[start]).group(0)
    new_ind = re.match(r"\s*", new[new_start]).group(0)
    reind = [old_ind + l[len(new_ind):] if l.startswith(new_ind) else l for l in new_gpu]
    lines[start + 1:end] = reind + other
    with open(path, "w") as f:
        f.write("\n".join(lines))


main()
