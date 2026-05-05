# Hammerspoon Dictation

> Voice dictation **anywhere** on macOS — press `Ctrl+D`, speak, and your words appear in whatever app you were using. Built specifically for **bilingual users** who mix languages mid-sentence (Korean + English, Spanish + English, etc.).

[![macOS](https://img.shields.io/badge/macOS-12%2B-black?logo=apple)](https://www.apple.com/macos/)
[![Apple Silicon](https://img.shields.io/badge/Apple%20Silicon-recommended-success)](https://support.apple.com/en-us/HT211814)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

```
You hold:  Ctrl + D
You say:   "내일 meeting 끝나고 final report 보내줄 수 있어?"
You get:   "내일 meeting 끝나고 final report 보내줄 수 있어?"
           ↑ pasted into Slack / Mail / VS Code / Notes / wherever
```

That's it. No web app, no upload to a SaaS, no clicking a microphone icon. Just a keystroke.

---

## Why this project exists

Built-in macOS dictation is fine if you only speak one language. But the moment you say something like:

> "I scheduled the **kickoff** for **다음 주 화요일**, can you forward the **agenda** to the team?"

… most dictation tools collapse. They either pick one language and phonetically mangle the other ("미팅", "다음 주 hwa-yo-il"), or they refuse to transcribe at all and leave you re-typing the bilingual half by hand.

If you're a bilingual researcher, engineer, student, or anyone whose daily writing is a 50/50 mix of two languages, you've felt this pain. **This tool is the answer.**

It runs locally on your Mac, works across every macOS app, and uses an ensemble approach to actually preserve code-switching — instead of fighting it.

---

## Who is this for?

- **Bilingual professionals** writing emails, Slack messages, or docs that naturally mix two languages
- **Researchers and academics** dictating notes, paper drafts, or feedback to students/collaborators across language boundaries
- **Software engineers** who want a fast hotkey-driven way to dictate commit messages, PR comments, or code comments without leaving their editor
- **Privacy-conscious users** who don't want their voice uploaded to a third-party server (whisper runs entirely on-device)
- **Anyone tired of macOS's built-in dictation** and looking for something that's *actually* good with proper nouns, technical jargon, and accented English

If your daily life involves typing into Slack, Mail, Outlook, VS Code, Notion, Obsidian, ChatGPT, Claude, the terminal — basically *any text field on macOS* — and you wish you could just talk instead, this is for you.

---

## What makes it different

| | macOS built-in | Whisper alone | ChatGPT voice | **Hammerspoon Dictation** |
|---|---|---|---|---|
| Works in any app | Yes | No (CLI only) | No (browser only) | **Yes** |
| Hotkey-triggered | Yes | No | No | **Yes** |
| Mixed languages in one sentence | Poor | Limited | OK | **Strong (v2 ensemble)** |
| Audio stays on-device | No (Apple) | **Yes** | No (OpenAI) | **Yes** (only text → Gemini) |
| Knows your jargon / colleagues' names | No | No | No | **Yes** (config file) |
| Cost | Free | Free | Subscription | Free + ~pennies/month for Gemini |
| Open source | No | Yes | No | **Yes (MIT)** |

The "knows your jargon" part is underrated. Whisper alone will hear an unfamiliar collaborator's name and butcher it phonetically (e.g. "Jiwon" → "Jee Won" → "Gee one"). With a tiny config listing your common collaborators, projects, and technical terms, Gemini fixes those automatically.

---

## Real-world examples

Typical situations the tool handles well:

**Email mixing both languages**
> Spoken: "다음 미팅에서 final approval 관련해서 팀에 confirm 받아야 해요"
> Pasted: "다음 미팅에서 final approval 관련해서 팀에 confirm 받아야 해요"

**Slack message in English**
> Spoken: "I think we should refactor the auth middleware before merging the PR"
> Pasted: "I think we should refactor the auth middleware before merging the PR"

**Note about an English paper, written in Korean**
> Spoken: "이 paper의 conclusion에서 4 dimensions로 정의한 부분이 핵심이야"
> Pasted: "이 paper의 conclusion에서 4 dimensions로 정의한 부분이 핵심이야"

**Quick reply in the terminal**
> Spoken: "git commit -m fix the regex bug in the parser"
> Pasted: `git commit -m fix the regex bug in the parser`

In every case, the cursor is already where you want the text. You don't switch apps, you don't click anything — you just keep working.

---

## How It Works

This repo ships **two pipelines** you can pick between. Both share the same hotkey + overlay UI; only the transcription stage differs.

### v1 — Single Whisper + Gemini correction (original)

```
Ctrl+D (start) ──> sox records audio ──> Ctrl+D (stop)
                                              │
                                              ▼
                                    whisper-cli -l ko (local, ~2s)
                                              │
                                              ▼
                                    Gemini 2.0 Flash (text fix)
                                              │
                                              ▼
                                    Auto-paste into original window
```

Fast and simple. Works great for **monolingual** speech (pure Korean *or* pure English). Struggles with sentences that mix the two — whisper is forced into one language and phonetically munges the other (e.g. "meeting" → "미팅").

### v2 — 3-way ensemble (default, better for code-switching)

```
Ctrl+D (start) ──> sox records audio ──> Ctrl+D (stop)
                                              │
                            ┌─────────────────┼─────────────────┐
                            ▼                 ▼                 ▼
                  whisper-cli -l ko   whisper-cli -l en   whisper-cli -l auto
                            │                 │                 │
                            └─────────────────┼─────────────────┘
                                              ▼
                            Gemini 2.0 Flash (merge 3 transcripts)
                                              │
                                              ▼
                                Auto-paste into original window
```

The audio is transcribed **three times in parallel**:

- `-l ko` accurately captures Korean portions; English is mangled into Hangul.
- `-l en` accurately captures English portions; Korean is mangled into roman letters.
- `-l auto` gives whisper's best single-language guess of the whole clip.

Gemini then receives all three transcripts and reconstructs the actual code-switched utterance — trusting each language's "expert" pass for its own portions. Wall-clock latency stays in the same ~3-4s range thanks to parallel execution; the trade-off is roughly 3× the Gemini token cost per dictation (still well within Gemini's free tier for normal personal use).

### Why an ensemble instead of one smarter model?

Whisper is brilliant at single-language audio but has a hard architectural limit: it commits to one language token at the start of each segment. Forcing `-l auto` doesn't fix code-switching — it just makes whisper guess which single language wins. Larger commercial models (gpt-4o-transcribe, Gemini-direct-audio) handle code-switching better, but they require sending your raw audio to the cloud.

The ensemble approach keeps the audio on your device, leverages a model whisper is *already* very good at (single-language transcription), and uses an LLM only to combine three text outputs. It's strictly cheaper, more private, and surprisingly accurate.

### Choosing a version

| | v1 | v2 |
|---|---|---|
| Korean only | excellent | excellent |
| English only | good | excellent |
| Korean + English mixed | weak | **strong** |
| Wall-clock latency | ~2-3s | ~3-4s |
| CPU at peak | 1× whisper | 3× whisper |
| Gemini tokens/call | ~1× | ~3× |
| Best for | Single-language speakers | Bilingual / code-switchers |

Run `./install.sh --version=v1` or `./install.sh --version=v2` to switch at any time. Default is **v2**.

> Although the examples here use **Korean + English**, the v2 ensemble works for any pair of languages whisper supports — just edit `v2/dictate.sh` and replace `-l ko` / `-l en` with the two language codes you mix (e.g. `-l es` and `-l en` for Spanish-English code-switching).

---

## Privacy

- **Audio never leaves your Mac.** Recording is done by `sox` to `/tmp/hs_dictate.wav`, transcribed by `whisper.cpp` running locally, then deleted on the next dictation.
- **Only the resulting text** is sent to Gemini for correction/merging — never the raw audio.
- **Your context config** (`dictate-config.json`) is local only and is **not** in the git repo (gitignored). The first dictation per session sends a small system prompt with the names/terms you've configured; nothing else.
- If you don't set `GEMINI_API_KEY`, the tool degrades gracefully to whisper's raw output. **Nothing leaves your Mac at all** in that mode.

---

## Requirements

- macOS 12 (Monterey) or newer
- Apple Silicon strongly recommended (M1/M2/M3/M4) — Whisper on Intel works but is much slower
- ~2 GB free disk space (for the Whisper large-v3-turbo model)
- A working microphone (built-in is fine)
- [Homebrew](https://brew.sh)
- [Gemini API key](https://aistudio.google.com/apikey) — free tier is plenty for personal use, optional

---

## Quick Start

```bash
git clone https://github.com/sunjinpak/hammerspoon-dictation.git
cd hammerspoon-dictation
chmod +x install.sh
./install.sh                    # installs v2 by default
# or:
./install.sh --version=v1       # if you only speak one language at a time
```

The installer will:
1. Install dependencies via Homebrew (`sox`, `whisper-cpp`, Hammerspoon)
2. Download the Whisper large-v3-turbo model (~1.5 GB) into `~/whisper-models/`
3. Copy the chosen version's scripts to `~/.hammerspoon/`

Then set your Gemini API key:

```bash
# Add to ~/.zshrc (or ~/.bash_profile)
export GEMINI_API_KEY="your-api-key-here"
```

Open Hammerspoon from Applications, grant **Accessibility** permissions when prompted (System Settings → Privacy & Security → Accessibility), and you're ready.

**First dictation:** put your cursor in any text field, press `Ctrl+D`, speak, press `Ctrl+D` again. Your text appears.

---

## Configuration

### Personal context (recommended)

Edit `~/.hammerspoon/dictate-config.json`. A `config.example.json` template is included in the repo — copy it and fill in your own details:

```json
{
  "name": "Your Name",
  "role": "Software Engineer at Acme Corp",
  "terms": [
    "React", "TypeScript", "Kubernetes", "PostgreSQL",
    "code-switching", "Hammerspoon", "whisper.cpp"
  ],
  "names": [
    "Alice", "Bob", "Charlie",
    "Jiwon", "Minji"
  ],
  "extra_context": [
    "Currently working on Project Phoenix",
    "Team members: Alice (frontend), Bob (backend)",
    "Frequently dictates in mixed languages"
  ]
}
```

This is the single biggest accuracy win. The LLM uses this to fix proper nouns and technical terms that Whisper consistently mangles. Update it as your work changes — projects, collaborators, jargon. Your config stays on your Mac and is never committed to this repo.

### Hotkey

Edit `init.lua`:

```lua
-- Default
hs.hotkey.bind({"ctrl"}, "d", function() ... end)

-- Examples
hs.hotkey.bind({"cmd", "shift"}, "d", function() ... end)   -- Cmd+Shift+D
hs.hotkey.bind({"alt"}, "space", function() ... end)        -- Option+Space
hs.hotkey.bind({"fn"}, "f5", function() ... end)            -- Fn+F5
```

After editing, reload with **`Cmd+Alt+Ctrl+R`**.

### Whisper language (v1 only)

v2 ignores `DICTATE_LANG` (it always runs ko/en/auto). For v1:

```bash
export DICTATE_LANG="ko"      # default
export DICTATE_LANG="en"      # English only
export DICTATE_LANG="auto"    # let whisper pick
```

If you mix languages often, just use v2 instead.

### Different language pairs (v2)

Edit `v2/dictate.sh` and change the two language codes:

```zsh
# Default: Korean + English
whisper-cli ... -l ko ... &
whisper-cli ... -l en ... &

# Spanish + English
whisper-cli ... -l es ... &
whisper-cli ... -l en ... &

# Mandarin + English
whisper-cli ... -l zh ... &
whisper-cli ... -l en ... &
```

Then edit `v2/dictate-fix.py`'s prompt to mention the actual language names instead of "Korean" / "English".

---

## File Structure

```
hammerspoon-dictation/      (this repo)
├── init.lua              # Hammerspoon hotkey + overlay UI (shared)
├── install.sh            # Installer (--version=v1|v2)
├── config.example.json   # Template for ~/.hammerspoon/dictate-config.json
├── v1/
│   ├── dictate.sh        # v1: single whisper -l ko + Gemini correction
│   └── dictate-fix.py
└── v2/
    ├── dictate.sh        # v2: 3-way parallel whisper + Gemini merge
    └── dictate-fix.py

~/.hammerspoon/             (after install)
├── init.lua              # copied from repo
├── dictate.sh            # copied from chosen version's folder
├── dictate-fix.py        # copied from chosen version's folder
└── dictate-config.json   # your personal context (not in repo)
```

---

## Tips & tricks

- **Speak naturally.** You don't have to enunciate or pause between languages. The ensemble handles "I'll send 그거 by tomorrow morning" just as well as cleanly-separated phrases.
- **Short clips dictate faster.** Whisper latency is roughly proportional to audio length, not text length. A 5-second utterance is better than a 30-second monologue.
- **The overlay tells you the state.** Red = recording, blue = processing. If it stays blue for more than ~10 seconds, something stalled — reload with `Cmd+Alt+Ctrl+R`.
- **Curse-words work.** Whisper transcribes them faithfully. The Gemini correction step doesn't sanitize anything by default.
- **Confidential text:** if you don't want even text sent to Gemini, just unset `GEMINI_API_KEY`. The tool will fall back to raw whisper output, which never leaves your Mac.
- **Combine with a clipboard manager** (Raycast, Maccy, etc.) for a quick history of recent dictations.

---

## Troubleshooting

**"No speech detected"**
Microphone may be muted, or you spoke for less than ~1 second. Check System Settings → Privacy & Security → Microphone and confirm Hammerspoon has access.

**Pasting goes to the wrong window**
The tool focuses the window that was active when you *started* recording. If you switched windows mid-recording, it'll still paste into the original. This is intentional — but if you want the current window, change `sourceWindow:focus()` to `nil` in `init.lua`.

**Correction not working / output is rough**
- Check `echo $GEMINI_API_KEY` in your shell. If empty, add to `~/.zshrc`.
- Verify the key works: `curl "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.0-flash:generateContent?key=$GEMINI_API_KEY" -d '{"contents":[{"parts":[{"text":"hello"}]}]}'`
- Free tier has a daily quota. If you hit it, the tool falls back to raw whisper output.

**Hammerspoon overlay frozen on "Processing..."**
- `Cmd+Alt+Ctrl+R` to reload Hammerspoon
- Or kill the recording process: `pkill -INT -f 'rec /tmp/hs_dictate.wav'`

**Whisper output is in the wrong language**
- v1: set `DICTATE_LANG` correctly, or switch to v2.
- v2: this is unusual — open an issue with a sample audio file.

**Hotkey doesn't fire**
- Confirm Hammerspoon is running (menu bar icon)
- Check Accessibility permission: System Settings → Privacy & Security → Accessibility → Hammerspoon (toggle on)
- Another app might have grabbed `Ctrl+D` — change the hotkey in `init.lua`

**Slow transcription on Intel Macs**
The large-v3-turbo model is ~1.5 GB and was tuned for Apple Silicon Metal acceleration. On Intel, swap to a smaller model:
```bash
curl -L -o ~/whisper-models/ggml-base.bin \
  "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.bin"
# Then edit dictate.sh: MODEL="$HOME/whisper-models/ggml-base.bin"
```
Accuracy drops, but transcription becomes 5-10× faster.

---

## FAQ

**Is this affiliated with Hammerspoon, OpenAI, or Google?**
No. This is an independent open-source project. Hammerspoon is the macOS automation framework it's built on, Whisper is OpenAI's open-weight model (running locally via [whisper.cpp](https://github.com/ggerganov/whisper.cpp)), and Gemini is Google's LLM (called via API for text correction).

**How much does Gemini cost?**
For typical personal use (a few dozen dictations a day), it stays within the free tier indefinitely. Each v2 dictation uses ~1-2k tokens of input + a few hundred tokens of output. Free tier as of 2026: 15 RPM, 1 M TPM, 1.5k requests/day on `gemini-2.0-flash`.

**Can I use OpenAI / Claude / a local LLM instead of Gemini?**
Yes — `dictate-fix.py` is a single short Python script. Replace the Gemini API call with whatever HTTP endpoint you prefer. PRs welcome.

**Does this work on Linux / Windows?**
Not as-is. Hammerspoon is macOS-only. The general approach (record → whisper → LLM-merge → paste) is portable; equivalent tools on Linux would be `xdotool` or `wtype`, on Windows `AutoHotkey` or `nircmd`.

**Why Hammerspoon and not a Swift menu-bar app?**
Hammerspoon is hackable — the entire tool is ~100 lines of Lua + 2 short shell/Python scripts. You can read all of it in 10 minutes and customize anything. A Swift app would be more polished but harder to fork.

**Can I record longer than ~30 seconds?**
Yes, there's no built-in time limit. Practical limit is the Whisper context window (~30s of audio is the model's optimal range). Longer clips work but accuracy can degrade.

**My language isn't Korean. Will v2 still help me?**
Yes. The ensemble approach is language-agnostic — it works for any language pair Whisper supports (~100 languages). See "Different language pairs" above.

---

## Contributing

Issues and PRs welcome. Some areas where help would be especially appreciated:

- Testing v2 with other code-switching language pairs (Spanish-English, Mandarin-English, French-English, Hindi-English, etc.) and tuning the merge prompt
- A small benchmark suite (sample audio + expected transcript) so we can measure regressions
- A Swift port for users who don't want the Hammerspoon dependency
- A `--version=v3` experiment that uses Gemini's direct-audio mode as a fourth ensemble member

If you build something cool on top of this, please drop a link in the issues — I'd love to see it.

---

## Acknowledgments

- [Hammerspoon](https://www.hammerspoon.org/) — the macOS automation framework that makes the hotkey + overlay possible
- [whisper.cpp](https://github.com/ggerganov/whisper.cpp) — Georgi Gerganov's blazing-fast C++ port of OpenAI Whisper
- [Google Gemini](https://ai.google.dev/) — fast, cheap, and surprisingly good at multilingual text correction
- The bilingual community everywhere who put up with bad dictation tools long enough to inspire this one

---

## License

[MIT](LICENSE) — do whatever you want with it. If it saves you typing, that's payment enough.
