#!/usr/bin/env python3
"""Case-based tests for dictation_inline_learn.py (the UserPromptSubmit hook).

Run after ANY change to the hook or to the dictation init.lua paste/learn path:
    python3 ~/.claude-local/hammerspoon/tests/test_inline_learn.py
Every case here is a real dictation that once went wrong (2026-09-02: a re-spoken Korean
correction was filed as context, and context-only captures sent no notification). Add the
next failure as a new case before fixing it. Nothing touches the real glossary, ledger or
Telegram: those functions are stubbed.
"""
import importlib.util, io, json, os, sys

_SIBLING = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "dictation_inline_learn.py")
HOOK = (os.environ.get("INLINE_LEARN_HOOK")
        or (os.path.abspath(_SIBLING) if os.path.exists(_SIBLING) else None)   # repo checkout: v4/tests/../
        or os.path.expanduser("~/.claude/hooks/dictation_inline_learn.py"))   # installed hook
spec = importlib.util.spec_from_file_location("hook", HOOK)
hook = importlib.util.module_from_spec(spec)
spec.loader.exec_module(hook)

# prompt -> expected (target, comment, destination) for each nested comment
CASES = [
    ("<이게 레그드 릴레이션십<lagged relationship>으로 테스트 한 거야.>",
     [("레그드 릴레이션십", "lagged relationship", "glossary")]),
    ("<이게 크로스 레그드 패널<cross-lagged panel> 모형이야.>",
     [("크로스 레그드 패널", "cross-lagged panel", "glossary")]),
    ("<좋아서 좋았어요.<좋았어 좋았어> 이것도 GitHub에 올려줘.>",
     [("좋아서 좋았어요", "좋았어 좋았어", "glossary")]),
    ("<코호트 파이브<코호트 5> 학생들에게 보내줘.>",
     [("코호트 파이브", "코호트 5", "glossary")]),
    ('<그<"그" 이건 빼도되.> 다음 문장>',
     [("그", '"그" 이건 빼도되.', "context")]),
    ("<이 문장은 마지막 단어<이 문장 전체를 빼> 끝>",
     [("단어", "이 문장 전체를 빼", "context")]),
    ("<중첩 코멘트가 없는 평범한 딕테이션.>", []),
    ("plain prompt without brackets", []),
]


def run_case(prompt):
    sent, glossary = [], []
    hook.telegram = lambda m: sent.append(m)
    hook.glossary_add = lambda t, c: (glossary.append((t, c)) or True)
    hook.OUT = os.devnull
    sys.stdin = io.StringIO(json.dumps({"prompt": prompt}))
    hook.main()
    return sent, glossary


def main():
    failures = 0
    for prompt, expected in CASES:
        sent, glossary = run_case(prompt)
        got = []
        for t, c in glossary:
            got.append((t, c, "glossary"))
        # context-only comments show up in the Telegram text but not in the glossary
        for t, c, dest in expected:
            if dest == "context":
                ok = sent and f"{t} -> {c}" in sent[0] and (t, c) not in glossary
                got.append((t, c, "context" if ok else "missing"))
        if expected and not sent:
            got.append(("", "", "no-telegram"))
        if not expected and sent:
            got.append(("", "", "unexpected-telegram"))
        ok = sorted(got) == sorted(expected)
        failures += 0 if ok else 1
        print(("PASS " if ok else "FAIL ") + prompt[:60] + ("" if ok else f"\n      expected {expected}\n      got      {got}"))
    print(f"\n{len(CASES) - failures}/{len(CASES)} passed")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
