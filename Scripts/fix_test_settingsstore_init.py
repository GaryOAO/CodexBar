#!/usr/bin/env python3
"""One-shot test cleanup: rewrite SettingsStore(...) calls in test files to the
slimmed init signature. The init now only accepts:
    userDefaults, configStore, codexCookieStore, claudeCookieStore,
    tokenAccountStore, performInitialProviderDetection
All other (removed-provider) arguments are dropped. Idempotent.
"""
import sys
import re

KEEP = {
    "userDefaults", "configStore", "codexCookieStore", "claudeCookieStore",
    "tokenAccountStore", "performInitialProviderDetection",
}


def split_top_level(s):
    """Split an argument list on top-level commas (ignore commas inside () [] {} and strings)."""
    args, depth, buf, i = [], 0, [], 0
    in_str = False
    while i < len(s):
        c = s[i]
        if in_str:
            buf.append(c)
            if c == "\\" and i + 1 < len(s):
                buf.append(s[i + 1]); i += 2; continue
            if c == '"':
                in_str = False
            i += 1; continue
        if c == '"':
            in_str = True; buf.append(c); i += 1; continue
        if c in "([{":
            depth += 1; buf.append(c)
        elif c in ")]}":
            depth -= 1; buf.append(c)
        elif c == "," and depth == 0:
            args.append("".join(buf)); buf = []
        else:
            buf.append(c)
        i += 1
    if "".join(buf).strip():
        args.append("".join(buf))
    return args


def find_call_end(text, open_idx):
    """Given index of '(' return index just past matching ')'."""
    depth, i, in_str = 0, open_idx, False
    while i < len(text):
        c = text[i]
        if in_str:
            if c == "\\":
                i += 2; continue
            if c == '"':
                in_str = False
        else:
            if c == '"':
                in_str = True
            elif c == "(":
                depth += 1
            elif c == ")":
                depth -= 1
                if depth == 0:
                    return i + 1
        i += 1
    return -1


def process(text):
    out = []
    idx = 0
    pat = re.compile(r"\bSettingsStore\(")
    while True:
        m = pat.search(text, idx)
        if not m:
            out.append(text[idx:]); break
        open_paren = m.end() - 1
        end = find_call_end(text, open_paren)
        if end == -1:
            out.append(text[idx:]); break
        inner = text[open_paren + 1:end - 1]
        args = split_top_level(inner)
        kept = []
        for a in args:
            label = a.strip().split(":", 1)[0].strip()
            if label in KEEP:
                kept.append(a.strip())
        rebuilt = "SettingsStore(" + ", ".join(kept) + ")"
        out.append(text[idx:m.start()])
        out.append(rebuilt)
        idx = end
    return "".join(out)


def main():
    changed = 0
    for path in sys.argv[1:]:
        with open(path, "r") as f:
            src = f.read()
        new = process(src)
        if new != src:
            with open(path, "w") as f:
                f.write(new)
            changed += 1
            print(f"fixed {path}")
    print(f"total changed: {changed}")


if __name__ == "__main__":
    main()
