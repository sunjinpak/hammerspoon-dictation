#!/usr/bin/env python3
"""Gemini-powered text correction for whisper transcription output.

Loads personal context from ~/.hammerspoon/dictate-config.json to improve
correction accuracy for proper nouns, domain-specific terms, etc.
"""
import sys, os, json, urllib.request

raw = sys.argv[1] if len(sys.argv) > 1 else ""
if not raw:
    sys.exit(1)

api_key = os.environ.get("GEMINI_API_KEY", "")
if not api_key:
    print(raw)
    sys.exit(0)

# Load user config for personal context
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
    context_block = "Context:\n" + "\n".join(context_lines) + "\n\n"

prompt = f"""Fix transcription errors in this dictated text. {context_block}Rules:
- Fix misheard words, wrong homophones, proper nouns
- Keep original language mix (e.g. Korean + English) as spoken
- Do NOT rephrase or restructure
- Output ONLY the corrected text

Text: {raw}"""

payload = {
    "contents": [{"parts": [{"text": prompt}]}],
    "generationConfig": {"temperature": 0.1, "maxOutputTokens": 1024}
}

url = f"https://generativelanguage.googleapis.com/v1beta/models/gemini-2.0-flash:generateContent?key={api_key}"
req = urllib.request.Request(url, data=json.dumps(payload).encode(), headers={"Content-Type": "application/json"})

try:
    with urllib.request.urlopen(req, timeout=10) as resp:
        data = json.loads(resp.read().decode())
        print(data["candidates"][0]["content"]["parts"][0]["text"].strip())
except Exception:
    print(raw)
