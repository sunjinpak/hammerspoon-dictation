#!/usr/bin/env python3
"""Nudge when the review queue is worth a sitting, and report whether it is working.

Run from launchd once a day. Sends one Telegram message when the pending queue
crosses a threshold, and includes the trailing accuracy so the loop is
falsifiable: if reviewing is not reducing the error rate, that shows up here
rather than being assumed.

Rate-limited to one nudge per QUIET_HOURS so a queue that sits unreviewed does
not turn into a daily nag -- the fastest way to make someone ignore the tool.

  --force   send regardless of threshold and rate limit
  --stats   print the report and exit, send nothing
"""

import json
import os
import subprocess
import sys
import time

HSDIR = os.path.dirname(os.path.abspath(__file__))
STATS = os.path.join(HSDIR, "glossary", "stats.jsonl")
GLOSSARY = os.path.join(HSDIR, "glossary", "terms.tsv")
STATE = os.path.join(HSDIR, "glossary", ".watch_state")
# Any executable taking the message as argv[1]. Falls back to printing, so this
# works with no configuration; point DICTATE_NOTIFY at whatever you already use
# (terminal-notifier, a Telegram/Slack shim, ntfy...).
NOTIFY = os.environ.get(
    "DICTATE_NOTIFY",
    os.path.expanduser("~/.claude/channels/telegram/send.sh"),
)

THRESHOLD = int(os.environ.get("REVIEW_THRESHOLD", "25"))
QUIET_HOURS = float(os.environ.get("REVIEW_QUIET_HOURS", "20"))

sys.path.insert(0, HSDIR)
import review  # noqa: E402  (same directory, no package)


def accuracy(window):
    """Share of recent reviewed clips whose pasted text needed no correction."""
    rows = []
    try:
        with open(STATS, encoding="utf-8") as f:
            for line in f:
                try:
                    rows.append(json.loads(line))
                except ValueError:
                    continue
    except OSError:
        return None, 0
    if not rows:
        return None, 0
    recent = rows[-window:]
    good = sum(1 for r in recent if r.get("correct"))
    return good / len(recent), len(recent)


def glossary_size():
    try:
        with open(GLOSSARY, encoding="utf-8") as f:
            return sum(1 for l in f if l.strip() and not l.startswith("#") and "\t" in l)
    except OSError:
        return 0


def report():
    pending = len(review.items())
    terms = glossary_size()
    recent, n_recent = accuracy(50)
    prior, n_prior = accuracy(200)

    lines = ["받아쓰기 검수 %d건 대기 중" % pending, ""]
    if recent is not None:
        lines.append("최근 %d건 정확도 %.0f%%" % (n_recent, recent * 100))
        # Only claim a trend when the wider window holds meaningfully more data;
        # otherwise the two windows overlap and the "change" is noise.
        if prior is not None and n_prior >= n_recent + 30:
            delta = (recent - prior) * 100
            lines.append("직전 %d건 대비 %+.0f%%p" % (n_prior, delta))
    lines.append("등록된 용어 %d개" % terms)
    lines.append("")
    lines.append("검수: python3 ~/.claude-local/hammerspoon/review.py")
    return pending, "\n".join(lines)


def recently_sent():
    try:
        with open(STATE) as f:
            return (time.time() - float(f.read().strip())) < QUIET_HOURS * 3600
    except (OSError, ValueError):
        return False


def mark_sent():
    try:
        os.makedirs(os.path.dirname(STATE), exist_ok=True)
        with open(STATE, "w") as f:
            f.write(str(time.time()))
    except OSError:
        pass


def main():
    force = "--force" in sys.argv
    pending, text = report()

    if "--stats" in sys.argv:
        print(text)
        return

    if not force:
        if pending < THRESHOLD:
            return
        if recently_sent():
            return

    if not os.path.exists(NOTIFY):
        print(text)
        return
    subprocess.run([NOTIFY, text], check=False)
    mark_sent()


if __name__ == "__main__":
    main()
