#!/usr/bin/env python3
"""Gemini-powered ensemble merger for whisper transcription output (v2).

Takes 3 whisper transcripts of the same audio:
  argv[1] = Korean-locked  (-l ko)
  argv[2] = English-locked (-l en)
  argv[3] = Auto-detect    (-l auto)

Gemini reconstructs the actual code-switched utterance by trusting each
language's expert pass for its own portions, and uses the speaker context
config to fix proper nouns / domain terms.
"""
import sys, os, json, urllib.request

if len(sys.argv) < 4:
    sys.exit(1)

ko_text = sys.argv[1].strip()
en_text = sys.argv[2].strip()
auto_text = sys.argv[3].strip()

# All three identical -> nothing to merge
if ko_text and ko_text == en_text == auto_text:
    print(ko_text)
    sys.exit(0)

api_key = os.environ.get("GEMINI_API_KEY", "")
if not api_key:
    # No Gemini -> prefer auto, fall back to ko, then en
    print(auto_text or ko_text or en_text)
    sys.exit(0)

# Load user context
config_path = os.path.join(os.path.expanduser("~"), ".hammerspoon", "dictate-config.json")
context_lines = []
try:
    with open(config_path) as f:
        config = json.load(f)
    if config.get("name"):
        context_lines.append(f"- Speaker: {config['name']}")
    if config.get("role"):
        context_lines.append(f"- Role: {config['role']}")
    if config.get("terms"):
        context_lines.append(f"- Common terms: {', '.join(config['terms'])}")
    if config.get("names"):
        context_lines.append(f"- Proper names: {', '.join(config['names'])}")
    if config.get("extra_context"):
        for line in config["extra_context"]:
            context_lines.append(f"- {line}")
except (FileNotFoundError, json.JSONDecodeError):
    pass

context_block = ""
if context_lines:
    context_block = "Speaker context:\n" + "\n".join(context_lines) + "\n\n"

prompt = f"""You are merging three whisper transcripts of the SAME audio clip. The speaker may use Korean, English, or both languages mixed within a single utterance (code-switching).

{context_block}Transcript A (Korean-locked):
{ko_text}

Transcript B (English-locked):
{en_text}

Transcript C (auto-detect, single dominant language):
{auto_text}

Reconstruction rules:
- For Korean portions, trust Transcript A. Transcript B will have mangled them into roman letters; ignore that mangling.
- For English portions, trust Transcript B. Transcript A will have mangled them into Hangul (e.g., "meeting" -> "미팅" written phonetically); ignore that mangling.
- Use Transcript C as a tiebreaker for word order, hesitations, and overall flow.
- Preserve the original code-switching exactly as spoken. Do NOT translate.
- Fix obvious proper-noun and homophone errors using the speaker context above.
- Do NOT rephrase, summarize, or add punctuation that isn't implied by the speech.
- Output ONLY the final merged text. No labels, no explanation, no quotes.

Final text:"""

payload = {
    "contents": [{"parts": [{"text": prompt}]}],
    "generationConfig": {"temperature": 0.1, "maxOutputTokens": 1024}
}

url = f"https://generativelanguage.googleapis.com/v1beta/models/gemini-2.0-flash:generateContent?key={api_key}"
req = urllib.request.Request(
    url,
    data=json.dumps(payload).encode(),
    headers={"Content-Type": "application/json"},
)

try:
    with urllib.request.urlopen(req, timeout=15) as resp:
        data = json.loads(resp.read().decode())
        print(data["candidates"][0]["content"]["parts"][0]["text"].strip())
except Exception:
    print(auto_text or ko_text or en_text)
