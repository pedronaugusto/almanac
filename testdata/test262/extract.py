"""Transcribes test262's Temporal string cases into temporal.json, once, as text: no JavaScript runs.

Usage: python3 -I extract.py <test262 checkout> <commit> > temporal.json

It reads test/built-ins/Temporal/<Type>/from/*.js for the types almanac shares and recognises the
shapes those files use: an array of strings each of which must throw a RangeError from
Temporal.<Type>.from, a table of [string, expected...] rows checked by TemporalHelpers.assert<Kind>
or by epochNanoseconds, and the same written inline. Anything else is counted, not guessed.
"""
import json, os, re, sys

TYPES = ["PlainDate", "PlainDateTime", "PlainTime", "Instant", "Duration", "ZonedDateTime"]
ASSERTS = {"PlainDate": "assertPlainDate", "PlainDateTime": "assertPlainDateTime", "PlainTime": "assertPlainTime", "Duration": "assertDuration"}

def body(src):
    end = src.find("---*/")
    return src[end + 5:] if end >= 0 else src

def string_at(s, i):
    """A JS string literal at s[i] (quote included): its value and the index after it."""
    q = s[i]
    out = []
    j = i + 1
    while j < len(s):
        c = s[j]
        if c == q:
            return "".join(out), j + 1
        if c == "\\":
            n = s[j + 1]
            if n == "u":
                if s[j + 2] == "{":
                    k = s.index("}", j)
                    out.append(chr(int(s[j + 3:k], 16)))
                    j = k + 1
                else:
                    out.append(chr(int(s[j + 2:j + 6], 16)))
                    j += 6
                continue
            out.append({"n": "\n", "t": "\t", "0": "\0"}.get(n, n))
            j += 2
            continue
        if c == "\n":
            return None, j
        out.append(c)
        j += 1
    return None, j

def tokens(s):
    """The literal tokens of an array body: strings, numbers, bigints, nested arrays."""
    items, stack, i = [], [[]], 0
    while i < len(s):
        c = s[i]
        if c in "\"'":
            v, i = string_at(s, i)
            if v is None:
                return None
            stack[-1].append(v)
            continue
        if c == "/" and s[i + 1] == "/":
            i = s.index("\n", i) if "\n" in s[i:] else len(s)
            continue
        if c == "[":
            stack.append([])
        elif c == "]":
            inner = stack.pop()
            stack[-1].append(inner)
        elif c == "-" or c.isdigit():
            m = re.match(r"-?\d+n?", s[i:])
            if not m:
                return None
            t = m.group(0)
            stack[-1].append(("bigint", t[:-1]) if t.endswith("n") else int(t))
            i += len(t)
            continue
        elif c in ", \n\t\r":
            pass
        else:
            return None
        i += 1
    return stack[0]

def arrays(src):
    """Each `const NAME = [ ... ];` of literals."""
    out = {}
    for m in re.finditer(r"const\s+(\w+)\s*=\s*\[", src):
        depth, i = 1, m.end()
        while i < len(src) and depth:
            c = src[i]
            if c in "\"'":
                _, i = string_at(src, i)
                continue
            if c == "[":
                depth += 1
            elif c == "]":
                depth -= 1
            i += 1
        t = tokens(src[m.end():i - 1])
        if t is not None:
            out[m.group(1)] = t
    return out

def matching(src, i, open_c, close_c):
    """The index after the bracket closing the one at src[i]."""
    depth, j = 0, i
    while j < len(src):
        c = src[j]
        if c in "\"'`":
            if c == "`":
                j = src.index("`", j + 1) + 1
            else:
                _, j = string_at(src, j)
            continue
        if c == open_c:
            depth += 1
        elif c == close_c:
            depth -= 1
            if depth == 0:
                return j + 1
        j += 1
    return len(src)

def loop_body(src, var):
    """The loop over `var`, as its variable (the first name where destructured) and its body."""
    m = re.search(r"for\s*\(\s*const\s+(\[[^\]]*\]|\w+)\s+of\s+" + var + r"\s*\)\s*\{", src)
    if m:
        name = re.findall(r"\w+", m.group(1))[0]
        return name, src[m.end() - 1:matching(src, m.end() - 1, "{", "}")]
    m = re.search(var + r"\.forEach\(\s*\(?\s*(\[[^\]]*\]|\w+)\s*\)?\s*=>", src)
    if m:
        name = re.findall(r"\w+", m.group(1))[0]
        open_at = src.index("(", m.start() + len(var))
        return name, src[open_at:matching(src, open_at, "(", ")")]
    return None

def call_args(block, head):
    """The top-level arguments of the first call `head(...)` in block, as text."""
    i = block.find(head)
    if i < 0:
        return None
    start = i + len(head) - 1
    inner = block[start + 1:matching(block, start, "(", ")") - 1]
    args, depth, cur, j = [], 0, "", 0
    while j < len(inner):
        c = inner[j]
        if c in "\"'`":
            k = (inner.index("`", j + 1) + 1) if c == "`" else string_at(inner, j)[1]
            cur += inner[j:k]
            j = k
            continue
        if c in "([{":
            depth += 1
        elif c in ")]}":
            depth -= 1
        if c == "," and depth == 0:
            args.append(cur.strip())
            cur = ""
        else:
            cur += c
        j += 1
    if cur.strip():
        args.append(cur.strip())
    return args

def main():
    root, commit = sys.argv[1], sys.argv[2]
    cases, seen, used = [], 0, 0
    for ty in TYPES:
        d = os.path.join(root, "test/built-ins/Temporal", ty, "from")
        for name in sorted(os.listdir(d)):
            if not name.endswith(".js"):
                continue
            seen += 1
            path = f"test/built-ins/Temporal/{ty}/from/{name}"
            src = body(open(os.path.join(d, name), encoding="utf-8").read())
            found = []
            call = f"Temporal.{ty}.from("
            throws_re = re.compile(r"assert\.throws\(\s*RangeError")
            throws = bool(throws_re.search(src)) and call in src
            for var, items in arrays(src).items():
                loop = loop_body(src, var)
                if not loop:
                    continue
                loopvar, block = loop
                if not re.search(r"Temporal\." + ty + r"\.from\(\s*" + re.escape(loopvar) + r"\b", block):
                    continue
                strings = [it if isinstance(it, str) else (it[0] if isinstance(it, list) and it and isinstance(it[0], str) else None) for it in items]
                if throws_re.search(block):
                    # The string alone: a throw from an options argument is the options'.
                    if not re.search(r"Temporal\." + ty + r"\.from\(\s*" + re.escape(loopvar) + r"\s*\)", block):
                        continue
                    for x in strings:
                        if x is not None:
                            found.append({"text": x, "expect": "throws"})
                    continue
                kind = ASSERTS.get(ty)
                args = call_args(block, "TemporalHelpers." + kind + "(") if kind else None
                if args is not None:
                    if any(a.startswith("...") for a in args):
                        for it in items:
                            if isinstance(it, list) and it and isinstance(it[0], str):
                                exp = [x for x in it[1:] if isinstance(x, int)]
                                found.append({"text": it[0], "expect": {"fields": exp}})
                    else:
                        exp = [int(a) for a in args[1:] if re.fullmatch(r"-?\d+", a)]
                        for x in strings:
                            if x is not None:
                                found.append({"text": x, "expect": {"fields": exp}})
                    continue
                if ty == "Instant" and ".epochNanoseconds" in block:
                    for it in items:
                        if isinstance(it, list) and len(it) == 2 and isinstance(it[0], str) and isinstance(it[1], tuple):
                            found.append({"text": it[0], "expect": {"epoch_ns": it[1][1]}})
            # Inline: assert<Kind>(Temporal.<Type>.from("..."), ...), or a const then assert<Kind>(const, ...).
            kind = ASSERTS.get(ty)
            if kind:
                for m in re.finditer(r"(?:const\s+(\w+)\s*=\s*)?Temporal\." + ty + r"\.from\(\s*([\"'])", src):
                    v, after = string_at(src, m.end() - 1)
                    if v is None or not re.match(r"\s*\)", src[after:]):
                        continue
                    var = m.group(1)
                    head = "TemporalHelpers." + kind + "("
                    if var:
                        a = re.search(re.escape(head) + r"\s*" + var + r"\s*,", src[after:])
                        if not a:
                            continue
                        args = call_args(src[after + a.start():], head)
                    else:
                        call = src.rfind(head, 0, m.start())
                        if call < 0 or src[call + len(head):m.start()].strip():
                            continue
                        args = call_args(src[call:], head)
                    if args:
                        nums = [int(x) for x in args[1:] if re.fullmatch(r"-?\d+", x)]
                        if nums:
                            found.append({"text": v, "expect": {"fields": nums}})
            for m in re.finditer(r"assert\.throws\(\s*RangeError\s*,\s*\(\)\s*=>\s*Temporal\." + ty + r"\.from\(\s*([\"'])", src):
                v, after = string_at(src, m.end() - 1)
                if v is not None and re.match(r"\s*\)", src[after:]):
                    found.append({"text": v, "expect": "throws"})
            if found:
                used += 1
                for f in found:
                    f["path"] = path
                    f["type"] = ty
                    cases.append(f)
    # test262's helpers default the fields left off at the end to zero.
    lengths = {"PlainDate": 3, "PlainDateTime": 9, "PlainTime": 6, "Duration": 10}
    for c in cases:
        if isinstance(c["expect"], dict) and "fields" in c["expect"]:
            f = c["expect"]["fields"]
            c["expect"]["fields"] = f + [0] * (lengths[c["type"]] - len(f))
    # One case per path, type, text and expectation.
    unique, keys = [], set()
    for c in cases:
        k = (c["path"], c["type"], c["text"], json.dumps(c["expect"], sort_keys=True))
        if k not in keys:
            keys.add(k)
            unique.append(c)
    json.dump({"commit": commit, "files_read": seen, "files_with_cases": used, "cases": unique}, sys.stdout, indent=1, ensure_ascii=False)
    sys.stdout.write("\n")

main()
