"""Sets my.apps.<key>.enable (or my.<key>.enable for top-level modules such as
vmstation) in a host file, keeping the rest of the file as it is.

Usage: app-set.py FILE KEY=true|false [KEY=true|false ...]
Keys starting with "my." are top-level modules (e.g. my.vmstation),
the others are applications under my.apps.

Handled forms, in this order:
  KEY.enable = true;            (also commented: # KEY.enable = true;)
  KEY = { ... enable = true; ... };
  missing                       -> a new line is added
"""
import re
import sys


def block_end(lines, start):
    """Index of the line that closes the { opened at lines[start]."""
    depth = 0
    for i in range(start, len(lines)):
        code = re.sub(r'"(\\.|[^"\\])*"', '""', lines[i]).split("#", 1)[0]
        depth += code.count("{") - code.count("}")
        if depth <= 0 and i > start:
            return i
        if depth <= 0 and i == start and "{" in code:
            return i
    raise SystemExit(f"unbalanced braces after line {start + 1}")


def indent_of(line):
    return re.match(r"\s*", line).group(0)


def set_inline(lines, i, value):
    """Block on a single line: { ... enable = X; ... }"""
    if re.search(r"\benable\s*=\s*(true|false);", lines[i]):
        lines[i] = re.sub(r"\benable\s*=\s*(true|false);", f"enable = {value};", lines[i], count=1)
    else:
        lines[i] = lines[i].replace("{", f"{{ enable = {value};", 1)


def set_in_block(lines, start, end, key, value):
    """Sets key.enable inside lines[start+1:end] (a { } block). True if done."""
    k = re.escape(key)
    for i in range(start + 1, end):
        m = re.match(rf"^(\s*)(#\s*)?{k}\.enable\s*=\s*(true|false);(.*)$", lines[i])
        if m:
            rest = "" if m.group(2) else m.group(4)
            lines[i] = f"{m.group(1)}{key}.enable = {value};{rest}"
            return True
    for i in range(start + 1, end):
        if re.match(rf"^\s*{k}\s*=\s*\{{", lines[i]):
            sub_end = block_end(lines, i)
            if sub_end == i:
                set_inline(lines, i, value)
                return True
            for j in range(i + 1, sub_end):
                m = re.match(r"^(\s*)enable\s*=\s*(true|false);(.*)$", lines[j])
                if m:
                    lines[j] = f"{m.group(1)}enable = {value};{m.group(3)}"
                    return True
            lines.insert(i + 1, f"{indent_of(lines[i])}  enable = {value};")
            return True
    return False


def top_level_insert(lines, text):
    """Adds a line before system.stateVersion (or before the last })."""
    for i, line in enumerate(lines):
        if re.match(r"^\s*system\.stateVersion\s*=", line):
            lines.insert(i, f"{indent_of(line)}{text}")
            return
    for i in range(len(lines) - 1, -1, -1):
        if lines[i].strip() == "}":
            lines.insert(i, f"  {text}")
            return
    raise SystemExit("cannot find where to add the setting")


def set_app(lines, key, value):
    apps = next((i for i, line in enumerate(lines)
                 if re.match(r"^\s*my\.apps\s*=\s*\{", line)), None)
    if apps is not None:
        end = block_end(lines, apps)
        if set_in_block(lines, apps, end, key, value):
            return
    if set_module(lines, f"my.apps.{key}", value, insert=False):
        return
    if apps is not None:
        lines.insert(apps + 1, f"{indent_of(lines[apps])}  {key}.enable = {value};")
    else:
        top_level_insert(lines, f"my.apps.{key}.enable = {value};")


def set_module(lines, path, value, insert=True):
    """path = "my.vmstation": my.vmstation.enable = X; or my.vmstation = { enable = X; };
    False if not found and insert is False."""
    p = re.escape(path)
    for i, line in enumerate(lines):
        m = re.match(rf"^(\s*)(#\s*)?{p}\.enable\s*=\s*(true|false);(.*)$", line)
        if m:
            rest = "" if m.group(2) else m.group(4)
            lines[i] = f"{m.group(1)}{path}.enable = {value};{rest}"
            return True
    for i, line in enumerate(lines):
        if re.match(rf"^\s*{p}\s*=\s*\{{", line):
            end = block_end(lines, i)
            if end == i:
                set_inline(lines, i, value)
                return True
            for j in range(i + 1, end):
                m = re.match(r"^(\s*)enable\s*=\s*(true|false);(.*)$", lines[j])
                if m:
                    lines[j] = f"{m.group(1)}enable = {value};{m.group(3)}"
                    return True
            lines.insert(i + 1, f"{indent_of(line)}  enable = {value};")
            return True
    if not insert:
        return False
    top_level_insert(lines, f"{path}.enable = {value};")
    return True


def main():
    if len(sys.argv) < 3:
        raise SystemExit(__doc__)
    path = sys.argv[1]
    with open(path) as f:
        lines = f.read().split("\n")
    for arg in sys.argv[2:]:
        key, _, value = arg.partition("=")
        if value not in ("true", "false") or not re.fullmatch(r"[A-Za-z0-9_.-]+", key):
            raise SystemExit(f"invalid argument: {arg}")
        if key.startswith("my."):
            set_module(lines, key, value)
        else:
            set_app(lines, key, value)
    with open(path, "w") as f:
        f.write("\n".join(lines))


main()
