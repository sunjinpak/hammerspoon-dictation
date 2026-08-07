#!/usr/bin/env python3
"""Review queued dictation clips and grow the substitution glossary.

    python3 review.py          # serves http://127.0.0.1:8777

Listen to a clip, confirm or correct the text, move on. Confirmed corrections are
diffed against the recognizer's raw output and the recurring term pairs are
appended to glossary/terms.tsv, which dictate-fix.py applies on every subsequent
dictation. That is the whole loop: reviewing makes the next dictation better.

Binds to 127.0.0.1 only. The clips are recordings of everything the user dictates
-- student records, IRB material -- so this must not be reachable off-device.
Stdlib only, no dependencies.
"""

import difflib
import html
import json
import os
import re
import socketserver
import sys
import urllib.parse
from http.server import BaseHTTPRequestHandler

HSDIR = os.path.dirname(os.path.abspath(__file__))
CORPUS = os.path.join(HSDIR, "corpus")
GLOSSARY = os.path.join(HSDIR, "glossary", "terms.tsv")
STATS = os.path.join(HSDIR, "glossary", "stats.jsonl")
PORT = int(os.environ.get("REVIEW_PORT", "8791"))

HANGUL = re.compile(r"[가-힣]")

# A promoted pair must look like a term, not a sentence. Long left-hand sides are
# almost always the reviewer rewriting a whole phrase, which does not generalize
# to the next utterance and would corrupt unrelated text via blind substitution.
MAX_TERM_CHARS = 20
MAX_TERM_TOKENS = 3


def items(include_reviewed=False):
    out = []
    if not os.path.isdir(CORPUS):
        return out
    for day in sorted(os.listdir(CORPUS)):
        d = os.path.join(CORPUS, day)
        if not os.path.isdir(d):
            continue
        for name in sorted(os.listdir(d)):
            if not name.endswith(".json"):
                continue
            path = os.path.join(d, name)
            try:
                with open(path, encoding="utf-8") as f:
                    rec = json.load(f)
            except (OSError, ValueError):
                continue
            if rec.get("reviewed") and not include_reviewed:
                continue
            stem = name[:-5]
            rec["id"] = "%s/%s" % (day, stem)
            rec["audio"] = "/audio/%s/%s.flac" % (day, stem)
            out.append(rec)
    return out


# Korean particles cling to the end of a term, so a pair learned as
# "앤서 키를 -> answer key를" fails the next time the user says "앤서 키가".
# Longest first so 으로 is tried before 로.
PARTICLES = ("에서", "으로", "한테", "까지", "부터", "에게", "이랑",
             "를", "을", "이", "가", "은", "는", "의", "에", "로", "와", "과", "도")

TERMLIKE = re.compile(r"^[0-9A-Za-z가-힣][0-9A-Za-z가-힣 .+&-]*$")


def _strip_particle(left, right):
    """Drop a particle both sides share, so the pair generalizes."""
    for p in PARTICLES:
        if left.endswith(p) and right.endswith(p):
            l2, r2 = left[: -len(p)].strip(), right[: -len(p)].strip()
            if l2 and r2 and l2 != r2:
                return l2, r2
            break
    return left, right


def _acceptable(left, right):
    if not left or not right or left == right:
        return False
    if len(left) > MAX_TERM_CHARS or len(right) > MAX_TERM_CHARS:
        return False
    # Reject anything that is not word-shaped: punctuation-only or
    # symbol-laden blocks are reviewer edits that do not generalize, and blind
    # substitution of them would corrupt unrelated utterances.
    if not TERMLIKE.match(left) or not TERMLIKE.match(right):
        return False
    # Substitution is plain substring replacement, and Korean agglutinates, so
    # there is no word boundary to anchor against. A one-syllable term therefore
    # fires inside unrelated words: "키" -> "key" would rewrite "키보드" as
    # "key보드". Two characters is the shortest that is reasonably safe, and it
    # applies to alphanumeric terms ("ac" -> "Mac") for the same reason.
    if len(left) < 2:
        return False
    return True


def derive_pairs(raw, truth):
    """Extract term-level (wrong -> right) pairs from one reviewed correction.

    Whole replaced blocks are too coarse: "에이피아이 게이트웨이 타임아웃 로그"
    -> "API gateway timeout log" is one block of four tokens, and stored whole it
    only ever fires on that exact phrase. When the two sides have the same token
    count they are aligned pairwise instead, which yields the four reusable
    terms. Uneven blocks fall back to the whole-block pair if it is short
    enough to plausibly be a single term.
    """
    a, b = raw.split(), truth.split()
    pairs = []
    for tag, i1, i2, j1, j2 in difflib.SequenceMatcher(None, a, b).get_opcodes():
        if tag != "replace":
            continue
        la, lb = a[i1:i2], b[j1:j2]
        if len(la) == len(lb):
            candidates = list(zip(la, lb))
        elif len(la) <= MAX_TERM_TOKENS and len(lb) <= MAX_TERM_TOKENS:
            candidates = [(" ".join(la), " ".join(lb))]
        else:
            continue
        for left, right in candidates:
            left, right = _strip_particle(left.strip(), right.strip())
            if _acceptable(left, right):
                pairs.append((left, right))
    return pairs


def load_glossary():
    pairs = {}
    try:
        with open(GLOSSARY, encoding="utf-8") as f:
            for line in f:
                if line.startswith("#") or "\t" not in line:
                    continue
                w, r = line.rstrip("\n").split("\t", 1)
                pairs[w.strip()] = r.strip()
    except OSError:
        pass
    return pairs


def add_to_glossary(new_pairs):
    existing = load_glossary()
    added = []
    for w, r in new_pairs:
        if w in existing:
            continue
        existing[w] = r
        added.append((w, r))
    if not added:
        return []
    os.makedirs(os.path.dirname(GLOSSARY), exist_ok=True)
    fd = os.open(GLOSSARY, os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o600)
    with os.fdopen(fd, "a", encoding="utf-8") as f:
        for w, r in added:
            f.write("%s\t%s\n" % (w, r))
    return added


def record_stat(ident, rec, correct):
    # `rec` is the on-disk record, which carries no id -- that is synthesized in
    # items() from the file path -- so the caller passes it in.
    try:
        os.makedirs(os.path.dirname(STATS), exist_ok=True)
        fd = os.open(STATS, os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o600)
        with os.fdopen(fd, "a", encoding="utf-8") as f:
            json.dump({"id": ident, "correct": correct,
                       "changed": rec.get("changed"),
                       "rejected": rec.get("rejected")}, f)
            f.write("\n")
    except OSError:
        pass


PAGE = """<!doctype html><meta charset=utf-8>
<title>Dictation review</title>
<style>
 body{font:16px -apple-system,sans-serif;max-width:760px;margin:40px auto;padding:0 20px}
 .n{color:#666;font-size:13px}
 .row{margin:18px 0}
 .lbl{font-size:12px;color:#888;text-transform:uppercase;letter-spacing:.5px}
 .txt{font-size:19px;line-height:1.5;padding:8px 0}
 input{width:100%;font-size:19px;padding:10px;border:2px solid #ccc;border-radius:6px;
       box-sizing:border-box;font-family:inherit}
 input:focus{border-color:#0a7;outline:none}
 button{font-size:15px;padding:10px 18px;margin-right:8px;border-radius:6px;
        border:1px solid #bbb;background:#f6f6f6;cursor:pointer}
 button.p{background:#0a7;color:#fff;border-color:#0a7}
 kbd{background:#eee;border:1px solid #ccc;border-radius:3px;padding:1px 5px;font-size:12px}
 #done{text-align:center;padding:60px 0;color:#666}
 .diff{background:#ffe9a8;border-radius:3px;padding:0 2px}
</style>
<div id=app></div>
<script>
let q=[],i=0;
async function boot(){q=await (await fetch('/api/queue')).json();draw()}
function esc(s){return s.replace(/[&<>"]/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c]))}
function draw(){
 const a=document.getElementById('app');
 if(i>=q.length){a.innerHTML='<div id=done><h2>검수 완료</h2><p class=n>'+q.length+'건 처리했습니다. 사전에 반영됐습니다.</p></div>';return}
 const i0=q[i];
 a.innerHTML=`
  <div class=n>${i+1} / ${q.length} &nbsp;·&nbsp; ${esc(i0.id)}${i0.rejected?' &nbsp;·&nbsp; <b>교정 거부됨</b>':''}</div>
  <div class=row><audio id=au src="${i0.audio}" controls autoplay style="width:100%"></audio></div>
  <div class=row><div class=lbl>받아쓴 원문</div><div class=txt>${esc(i0.raw||'')}</div></div>
  <div class=row><div class=lbl>교정 결과 (붙여넣어진 것)</div>
    <input id=t value="${esc(i0.fixed||i0.raw||'')}"></div>
  <div class=row>
    <button class=p onclick="ok()">맞음 <kbd>Enter</kbd></button>
    <button onclick="save()">고쳐서 저장 <kbd>Shift+Enter</kbd></button>
    <button onclick="skip()">건너뛰기 <kbd>Esc</kbd></button>
  </div>
  <div class=n>재생 <kbd>Space</kbd> (입력칸 밖에서)</div>`;
 const t=document.getElementById('t');t.focus();t.setSelectionRange(t.value.length,t.value.length);
}
async function send(truth,skip){
 if(!skip&&!(truth||'').trim()){
   const t=document.getElementById('t');
   t.style.borderColor='#c33';t.placeholder='비어 있습니다. 내용을 넣거나 Esc로 건너뛰세요';
   t.focus();return;
 }
 const r=await fetch('/api/review',{method:'POST',headers:{'Content-Type':'application/json'},
   body:JSON.stringify({id:q[i].id,truth:truth,skip:!!skip})});
 if(!r.ok){alert('저장 실패: '+(await r.text()));return}
 i++;draw();
}
function ok(){send(document.getElementById('t').value,false)}
function save(){send(document.getElementById('t').value,false)}
function skip(){send(null,true)}
document.addEventListener('keydown',e=>{
 if(i>=q.length)return;
 if(e.key==='Enter'){e.preventDefault();ok()}
 else if(e.key==='Escape'){e.preventDefault();skip()}
 else if(e.key===' '&&e.target.tagName!=='INPUT'){e.preventDefault();
   const a=document.getElementById('au');a.paused?a.play():a.pause()}
});
boot();
</script>"""


class Handler(BaseHTTPRequestHandler):
    def _send(self, code, body, ctype="application/json; charset=utf-8"):
        if isinstance(body, str):
            body = body.encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        path = urllib.parse.urlparse(self.path).path
        if path == "/":
            return self._send(200, PAGE, "text/html; charset=utf-8")
        if path == "/api/queue":
            return self._send(200, json.dumps(items(), ensure_ascii=False))
        if path.startswith("/audio/"):
            rel = urllib.parse.unquote(path[len("/audio/"):])
            full = os.path.realpath(os.path.join(CORPUS, rel))
            # Confine to CORPUS: `rel` comes off the wire.
            if not full.startswith(os.path.realpath(CORPUS) + os.sep) or not os.path.isfile(full):
                return self._send(404, b"not found", "text/plain")
            with open(full, "rb") as f:
                return self._send(200, f.read(), "audio/flac")
        return self._send(404, b"not found", "text/plain")

    def do_POST(self):
        if urllib.parse.urlparse(self.path).path != "/api/review":
            return self._send(404, b"not found", "text/plain")
        n = int(self.headers.get("Content-Length", 0))
        try:
            req = json.loads(self.rfile.read(n) or b"{}")
        except ValueError:
            return self._send(400, json.dumps({"error": "bad json"}))

        ident = req.get("id", "")
        if "/" not in ident or ".." in ident:
            return self._send(400, json.dumps({"error": "bad id"}))
        day, stem = ident.split("/", 1)
        jpath = os.path.realpath(os.path.join(CORPUS, day, stem + ".json"))
        if not jpath.startswith(os.path.realpath(CORPUS) + os.sep) or not os.path.isfile(jpath):
            return self._send(404, json.dumps({"error": "no such item"}))

        with open(jpath, encoding="utf-8") as f:
            rec = json.load(f)

        if req.get("skip"):
            rec["reviewed"] = True
            rec["skipped"] = True
            with open(jpath, "w", encoding="utf-8") as f:
                json.dump(rec, f, ensure_ascii=False, indent=1)
            return self._send(200, json.dumps({"added": []}))

        truth = (req.get("truth") or "").strip()
        if not truth:
            # An empty correction is never a valid answer: it marks the clip
            # reviewed, drops it from the queue, and scores it as an error --
            # losing the recording's only chance at ground truth. Skipping is
            # the explicit way to pass on an item.
            return self._send(400, json.dumps(
                {"error": "empty truth; use skip to pass"}, ensure_ascii=False))
        rec["truth"] = truth
        rec["reviewed"] = True
        with open(jpath, "w", encoding="utf-8") as f:
            json.dump(rec, f, ensure_ascii=False, indent=1)

        record_stat(ident, rec, correct=(truth == (rec.get("fixed") or "")))
        added = add_to_glossary(derive_pairs(rec.get("raw") or "", truth))
        return self._send(200, json.dumps({"added": added}, ensure_ascii=False))

    def log_message(self, *a):
        pass  # the default logger prints every request, including audio paths


def main():
    pending = len(items())
    if not pending:
        print("검수할 항목이 없습니다.")
        return
    print("검수 대기 %d건  ->  http://127.0.0.1:%d" % (pending, PORT))
    print("Ctrl+C 로 종료")
    socketserver.TCPServer.allow_reuse_address = True
    try:
        srv = socketserver.TCPServer(("127.0.0.1", PORT), Handler)
    except OSError as e:
        # Do not hunt for a free port silently: another service on this port is
        # someone else's, and quietly landing on a different one makes the URL
        # printed above wrong.
        print("포트 %d 사용 중입니다 (%s). REVIEW_PORT=<번호> 로 바꿔서 실행하세요."
              % (PORT, e))
        sys.exit(1)
    with srv:
        try:
            srv.serve_forever()
        except KeyboardInterrupt:
            print("\n종료")


if __name__ == "__main__":
    main()
