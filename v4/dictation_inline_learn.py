#!/usr/bin/env python3
"""UserPromptSubmit hook: harvest dictation corrections the user gives inline.

Dictation pastes as <...>. When the user dictates a comment on top of an
existing <...> the result nests: <... word<comment> ...>. The inner bracket is
the user's correction of the outer text (2026-09-01: "그<"그" 이건 빼도되.>").
Each such pair is appended to inline_learn.jsonl; dictate-fix.py feeds the
recent ones back to the corrector as context, and /recap reviews them.

2026-09-02 (Prof. Pak): when the comment is a term (short, ASCII), it is also written straight
into glossary/terms.tsv as a permanent replacement rule, taking as many preceding words as the
term has (레그드 릴레이션십<lagged relationship> -> "레그드 릴레이션십\tlagged relationship"), and a
Telegram note confirms what was learned. Instruction-style comments ("이건 빼도되") stay
context-only.

Never blocks, never prints: a failure here must not touch the prompt.
"""
import json, os, re, subprocess, sys, time

OUT = os.path.expanduser("~/.claude-local/hammerspoon/corpus/inline_learn.jsonl")
GLOSSARY = os.path.expanduser("~/.claude-local/hammerspoon/glossary/terms.tsv")
SEND = os.path.expanduser("~/.claude/channels/telegram/send.sh")
TERM_RE = re.compile(r"^[A-Za-z][A-Za-z0-9 .&/\-]{0,60}$")


def is_term(comment):
    return bool(TERM_RE.match(comment)) and len(comment.split()) <= 4


def glossary_add(target, comment):
    """Append 'target<TAB>comment' unless the same wrong-hearing is already listed."""
    if not target or not comment:
        return False
    try:
        with open(GLOSSARY, encoding="utf-8") as f:
            for line in f:
                if line.startswith("#"):
                    continue
                if line.split("\t")[0].strip() == target:
                    return False
    except OSError:
        pass
    os.makedirs(os.path.dirname(GLOSSARY), exist_ok=True)
    fd = os.open(GLOSSARY, os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o600)
    with os.fdopen(fd, "a", encoding="utf-8") as f:
        f.write(f"{target}\t{comment}\n")
    return True


def telegram(msg):
    try:
        subprocess.run([SEND, msg], timeout=15, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except Exception:
        pass

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
    learned = []   # went into glossary/terms.tsv (permanent)
    context = []   # went into inline_learn.jsonl only (corrector context, last 10)
    for m in re.finditer(r"<([^<>]+)>", inner):
        before = inner[:m.start()].rstrip()
        words = re.sub(r"[.,!?]+$", "", before).split()
        comment = m.group(1).strip()
        # A term usually replaces as many spoken words as it has (레그드 릴레이션십 -> lagged relationship).
        # Hyphenated English is spoken as separate words (cross-lagged -> 크로스 레그드), so count them.
        n = len(re.split(r"[\s\-]+", comment)) if is_term(comment) else 1
        target = " ".join(words[-n:]) if words else ""
        comments.append({"target": target, "comment": comment})
        if is_term(comment):
            if glossary_add(target, comment):
                learned.append(f"{target} -> {comment}")
            else:
                context.append(f"{target} -> {comment} (용어집에 이미 있음)")
        else:
            context.append(f"{target} -> {comment}")
    if not comments:
        return
    # Prof. Pak (2026-09-02): say what was learned and where, every time, not only for glossary hits.
    msg = []
    if learned:
        msg.append("용어집 등록 (영구):\n" + "\n".join(learned))
    if context:
        msg.append("교정 컨텍스트 반영 (최근 10건):\n" + "\n".join(context))
    telegram("딕테이션 학습\n" + "\n".join(msg))
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
