# Hammerspoon Dictation

> Voice dictation **anywhere** on macOS — press `Ctrl+D`, speak, and your words appear in whatever app you were using. No web app, no upload to a SaaS, no clicking a microphone icon. Just a keystroke.

[![macOS](https://img.shields.io/badge/macOS-26%2B%20(v3)%20%7C%2012%2B%20(v1)-black?logo=apple)](https://www.apple.com/macos/)
[![Apple Silicon](https://img.shields.io/badge/Apple%20Silicon-recommended-success)](https://support.apple.com/en-us/HT211814)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

```
You hold:  Ctrl + D
You say:   "내일 미팅 끝나고 리포트 보내줄 수 있어?"
You get:   pasted into Slack / Mail / VS Code / Notes / wherever
```

**v3 (current)** transcribes on Apple's own on-device Speech framework: **~0.35s**, no model file to download, no API key, no network, no cost. If you are on macOS 26 or later, use v3.

---

## Why this project exists

macOS has built-in dictation, but it is modal: you click into a field, trigger it, and it owns the input while it runs. This tool is a hotkey that drops text wherever your cursor already is, in any app, and then gets out of the way.

It also does the boring-but-necessary parts that a five-line script skips: it refuses to paste when you did not actually say anything, it does not clobber your clipboard, it cancels cleanly, and it cannot get stuck in a state where the hotkey stops responding.

---

## Who is this for?

- Anyone who types into Slack, Mail, Outlook, VS Code, Notion, Obsidian, ChatGPT, Claude, or a terminal all day and would rather talk
- **Privacy-conscious users** — v3 and v1's transcription stage run entirely on-device
- People who want dictation available in **every** app behind one consistent keystroke

---

## Honest comparison

| | macOS built-in | Whisper alone | **This tool (v3)** |
|---|---|---|---|
| Works in any app | Modal / per-field | No (CLI only) | **Yes** |
| Hotkey-triggered | Partly | No | **Yes** |
| Speed (short utterance) | Fast | ~1.6s | **~0.35s** |
| Audio stays on-device | Yes | **Yes** | **Yes** |
| Needs a model download | No | Yes (0.5-1.5 GB) | **No** |
| Cost | Free | Free | **Free** |
| Mixed languages in one sentence | Poor | Poor | **Poor** (see below) |
| Open source | No | Yes | **Yes (MIT)** |

### About code-switching — read this before you install

Earlier versions of this project advertised code-switching (mixing two languages mid-sentence) as the headline feature. **That claim did not survive measurement, and it has been removed.**

What was actually measured on an M-series Mac (2026-08):

- **Whisper locked to one language** splits foreign words phonetically. Speaking "여기에 answer key가 없는데" with `-l ko` yields `answer 키` — half the English phrase transliterated.
- **`-l auto` changes nothing.** Whisper commits to one dominant language per segment; auto-detect just picks the winner.
- **The v2 "3-way ensemble" does not work.** Running `-l ko`, `-l en`, and `-l auto` in parallel and merging was the previous default. The English pass on Korean audio does not report failure — it **invents fluent, grammatical English nonsense** (real output: *"So, I'm going to use it like this. Then, I'm going to use it in English, so I'm going to use it in English."*). Because the wrong answer is well-formed, there is no signal a merge step can use to tell which pass was right. The premise was wrong, not the implementation.
- **It was also slower**, not faster: 7.94s for three parallel passes vs 1.56s for one, because whisper.cpp's Metal command queue serializes work across processes.
- **The macOS 26 Speech framework transliterates too**, for the same architectural reason.

So: **if you speak one language per utterance, this tool is excellent. If you routinely mix two languages inside one sentence, no version here solves that.** The honest fix is an LLM post-correction step that restores transliterated words — see [Optional: LLM correction](#optional-llm-correction). That requires a cloud API, which is why it is not the default.

If you want to dig into the code-switching ASR problem itself, [HiKE (EACL 2026)](https://aclanthology.org/2026.findings-eacl.33/) is a good starting point; it is an open research problem, not a configuration mistake.

---

## How It Works

Three pipelines ship here. All share the same hotkey and overlay UI; only the transcription stage differs.

### v3 — macOS Speech framework (recommended, default)

```
Ctrl+D (start) ──> sox records audio ──> Ctrl+D (stop)
                                              │
                                              ▼
                                    energy gate (sox RMS)
                                              │
                                              ▼
                              mac-stt (SpeechAnalyzer, ~0.35s)
                                              │
                                              ▼
                                   paste into source window
```

`mac-stt` is a small Swift CLI wrapping `SpeechAnalyzer` / `SpeechTranscriber` (macOS 26+). Fully offline, no API key, no model file. `whisper-cli` remains an automatic fallback if the locale asset is missing.

Requires **macOS 26+** and the Swift toolchain (ships with Xcode Command Line Tools) to compile once.

### v1 — Single Whisper + optional Gemini correction

```
Ctrl+D ──> sox ──> whisper-cli -l <lang> (~1.6s) ──> optional Gemini text fix ──> paste
```

Works on **macOS 12+**. Use this if you are not on macOS 26 yet. Needs a whisper.cpp model in `~/whisper-models/`.

### v2 — 3-way ensemble (deprecated, do not use)

Kept only as a record of a failed approach. See [About code-switching](#about-code-switching--read-this-before-you-install) for why it does not work and is also slower.

---

## What v3 gets right beyond transcription

These are the failure modes that make a dictation tool annoying in daily use. Each was found by measurement, not guesswork:

| Behavior | Why it matters |
|---|---|
| **Energy gate before transcribing** | Both whisper and the Apple engine invent text from near-silence — whisper reliably emits `감사합니다` (Korean "thank you") on a silent recording. An accidental double-tap would otherwise paste words you never said. Gated on `sox` RMS with peak-amplitude and byte-size fallbacks, and it logs loudly rather than silently disabling itself. |
| **Clipboard is preserved** | Dictation should not cost you whatever you had copied. Saved and restored around the paste, with a guard so two dictations in quick succession cannot chain and restore the wrong value. |
| **PID-based stop** | Signalling `rec` via `pkill` pattern-matching loses the signal if you double-tap before `rec` has spawned, which hangs the tool permanently. v3 signals the exact PID, with a retry. |
| **Watchdog** | A hung transcription can no longer leave the hotkey dead until a manual reload. |
| **ESC cancels** | Discards the recording without transcribing or pasting. |
| **Focus-verified paste** | Retries until the target window is genuinely focused, then falls back to leaving text on the clipboard with an alert — instead of pasting into whatever window happened to be in front. |
| **Errors say what broke** | A missing dependency reports itself as a missing dependency, not as "no speech detected". |
| **Recording cap** | 5 minutes, so a forgotten session cannot fill `/tmp`. |

---

## Install

```bash
git clone https://github.com/sunjinpak/hammerspoon-dictation.git
cd hammerspoon-dictation
./install.sh                  # v3 (default, macOS 26+)
./install.sh --version=v1     # v1 (macOS 12+, needs a whisper model)
```

Prerequisites:

```bash
brew install hammerspoon sox
# v1 only:
brew install whisper-cpp
mkdir -p ~/whisper-models && curl -L -o ~/whisper-models/ggml-large-v3-turbo.bin \
  "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin"
```

Then grant Hammerspoon **Microphone** and **Accessibility** permission in System Settings → Privacy & Security, and reload Hammerspoon.

### Configuration

Environment variables (all optional):

| Variable | Default | Purpose |
|---|---|---|
| `DICTATE_LOCALE` | `ko-KR` | Speech locale for v3. Set to `en-US` etc. |
| `DICTATE_MIN_RMS` | `0.003` | Silence threshold. Measured reference: room silence ≈ 0.00015, speech ≈ 0.05. |
| `DICTATE_MAX_SECONDS` | `300` | Recording cap. |
| `DICTATE_DEBUG` | `0` | Set to `1` to log to `dictate.log`. |

> **Important:** Hammerspoon runs scripts with a minimal `PATH` and reads neither `~/.zshrc` nor `~/.zprofile`. Anything you rely on must be on an absolute path or added to `PATH` inside the script (v3 does this). Environment variables must be set via `launchctl setenv`, not your shell profile — a variable exported in `~/.zshrc` is **invisible** to the dictation pipeline. This is a genuinely easy way to build a feature that silently never runs.

Dictated text is pasted wrapped in `<...>` in every app. Set `wrapInBrackets = false` in `init.lua` to paste plain text instead.

---

## Optional: LLM correction

If you mix two languages in one sentence and want transliterated words restored (`앤서 키` → `answer key`), add an LLM pass after transcription. Measured latencies for one short sentence:

| Approach | Latency | Verdict |
|---|---|---|
| Gemini 2.5 Flash (text-only correction) | **0.6s** | Works. Needs a cloud API. |
| Gemini 2.5 Flash (audio-native, replaces ASR) | 2.9s | Most accurate on code-switching. Sends audio off-device. |
| Local LLM via ollama (2.4b-32b) | 0.4s-134s | **Failed at every size tested.** |
| Coding-agent CLI | 14-20s | Accurate but far too slow, and non-deterministic. |

Local models failed in instructive ways: a 2.4b model read an imperative sentence as an instruction and wrote an entire email in reply; a 7.8b model silently changed the speaker's register and introduced typos; a 32b model took over 100s per sentence and still mistranslated. The task looks trivial but is mostly about **restraint** — knowing what not to touch — and small models are weakest exactly there.

Cost for the text-only path is roughly $0.40/month at 50 dictations/day. Note that free API tiers may use your input for training; if you dictate anything sensitive, use a paid tier or skip this step.

This is deliberately not wired in by default: v3's whole point is that it needs nothing but your Mac.

---

## Performance notes

Measured on an M-series Mac, short utterance, 2026-08:

| Engine | Latency | On silence |
|---|---|---|
| **macOS 26 Speech (v3)** | **0.35s** | Returns nothing (correct) |
| whisper `large-v3-turbo` | 1.56s | Hallucinates `감사합니다` |
| whisper `medium-q5_0` | 1.07s | Same hallucination |
| whisper 3-way ensemble (v2) | 7.94s | Same, plus fabricated English |

No whisper flag suppresses the silence hallucination: `--suppress-nst`, `--no-fallback`, and `--no-speech-thold 0.3` were all tested and all still produced text on a silent file. The energy gate is not optional.

**Bluetooth microphones clip the first ~1s** of speech: the HFP/SCO profile switch adds ~1.0s of device-open latency, during which `rec` writes nothing while the overlay already shows "Recording". Neither an idle warm-keeper process nor switching to ffmpeg avfoundation fixes it. Use a wired or USB microphone. A single persistent capture stream would be the real fix, and is not implemented.

---

## Troubleshooting

| Symptom | Fix |
|---|---|
| "No speech detected" every time | Check Hammerspoon has Microphone permission. Run `DICTATE_DEBUG=1` and read `dictate.log`. |
| "Dictation error: rec (SoX) not found" | `brew install sox`, or add its directory to `PATH` inside `dictate.sh`. |
| Stuck on "Processing..." | The watchdog resets after 330s; `Cmd+Alt+Ctrl+R` reloads immediately. |
| Kill a stuck recording | `kill -INT $(cat /tmp/hs_dictate.pid)` |
| First second of speech missing | You are on a Bluetooth mic. See Performance notes. |
| Rebuild `mac-stt` | `swiftc -O mac-stt.swift -o mac-stt` |

---

## License

MIT
