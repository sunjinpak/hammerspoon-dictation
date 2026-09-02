#!/usr/bin/env python3
"""UserPromptSubmit hook: harvest dictation corrections the user gives inline.

Dictation pastes as <...>. When the user dictates a comment on top of an
existing <...> the result nests: <... word<comment> ...>. The inner bracket is
the user's correction of the outer text (2026-09-01: "그<"그" 이건 빼도되.>").
Each such pair is appended to inline_learn.jsonl; dictate-fix.py feeds the
recent ones back to the corrector as context, and /recap reviews them.

Never blocks, never prints: a failure here must not touch the prompt.
"""
import json, os, re, sys, time

OUT = os.path.expanduser("~/.claude-local/hammerspoon/corpus/inline_learn.jsonl")

def main():
    try:
        prompt = json.load(sys.stdin).get("prompt", "")
    except Exception:
        return
    p = prompt.strip()
    if not (p.startswith("<") and p.endswith(">")):
        return
    inner = p[1:-1]
    comments = []
    for m in re.finditer(r"<([^<>]+)>", inner):
        before = inner[:m.start()].rstrip()
        target = before.split()[-1] if before.split() else ""
        comments.append({"target": target, "comment": m.group(1).strip()})
    if not comments:
        return
    clean = re.sub(r"<[^<>]+>", "", inner)
    clean = re.sub(r"\s{2,}", " ", clean).strip()
    rec = {"ts": time.strftime("%Y-%m-%d %H:%M:%S"), "outer": clean, "comments": comments}
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    fd = os.open(OUT, os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o600)
    with os.fdopen(fd, "a", encoding="utf-8") as f:
        f.write(json.dumps(rec, ensure_ascii=False) + "\n")

if __name__ == "__main__":
    try:
        main()
    except Exception:
        pass
