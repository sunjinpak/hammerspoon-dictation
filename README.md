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

**v3** transcribes on Apple's own on-device Speech framework: **~0.35s**, no model file to download, no API key, no network, no cost. If you are on macOS 26 or later and speak one language at a time, v3 is all you need.

**v4 (current)** adds an optional correction stage for people who mix English into another language mid-sentence — the one thing v3 genuinely cannot do. It restores transliterated words (`앤서 키` → `answer key`), and it **learns your vocabulary from your own corrections**, so recurring terms stop costing an API call at all. Roughly $0.40/month at 150 dictations/day. It is opt-in: v3 remains the default if you leave the API key unset.

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

So: **if you speak one language per utterance, this tool is excellent.** No amount of local engine configuration fixes mixed-language speech — that conclusion has now survived four separate attempts (see [What did not work](#what-did-not-work)).

**v4 fixes it the only way that actually worked: post-correction by a cloud LLM, plus a glossary you build from your own corrections.** Measured on real dictation, 3–4% error rate, essentially all of it on English words. It costs ~0.7s and ~$0.40/month, and it sends your transcript text to Google — which is why it is opt-in and off unless you supply a key. See [v4](#v4--correction--a-learning-glossary).

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

### v4 — correction + a learning glossary

```
Ctrl+D ──> sox ──> energy gate ──> mac-stt (0.35s)
                                        │
                                        ▼
                          glossary substitution (0ms, offline)
                                        │
                          ┌─────────────┴─────────────┐
                   nothing left                  still Hangul
                          │                           │
                          ▼                           ▼
                        paste            Gemini Flash-Lite (~0.7s)
                                                      │
                                                      ▼
                                          sanitize ──> paste
                                                      │
                                                      ▼
                                    corpus/  (sampled, for review)
```

Two things make this more than "call an LLM on the output":

**The glossary comes first, and it grows.** `review.py` plays back sampled clips, you confirm or correct the text, and confirmed term pairs are diffed out and appended to `glossary/terms.tsv`. Those are then applied deterministically on every later dictation. This matters because the model is *inconsistent* on its own — it returned `dictation` for one utterance and `딕테이션` for the next, same word. A confirmed term should not be a coin flip.

**Everything fails open.** Any failure in the correction stage — no key, timeout, HTTP error, implausible output — pastes the raw transcript instead. Losing your words is a worse outcome than leaving them uncorrected, so there are three layers: the Python echoes its input, the shell guards against empty output, and a SIGALRM backstop bounds the whole thing well inside the watchdog window.

Requires a [Gemini API key](https://aistudio.google.com/apikey). Leave it unset and v4 behaves exactly like v3.

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

## The review loop (v4)

The point is not to review recordings. The point is that reviewing makes the next dictation better, and you can see whether it is working.

```bash
python3 review.py     # http://127.0.0.1:8791
```

Play, confirm with `Enter`, correct and `Enter`, or `Esc` to pass. Around 5 seconds each.

**What gets kept for review.** Not everything — a queue nobody can finish stops being reviewed at all. Every utterance the corrector changed, every correction it *rejected* (otherwise indistinguishable from "nothing needed fixing"), and 1-in-20 of the untouched ones so that errors both stages missed stay visible.

**What gets learned.** Corrections are diffed against the raw transcript at the token level, so `에이피아이 게이트웨이 타임아웃 로그` → `API gateway timeout log` yields four reusable terms rather than one phrase that only ever matches itself.

**Two guards that are not optional in Korean**, both found by having the tool corrupt real text:

- *Boundary matching.* Korean agglutinates, so plain substring replacement is unsafe. With `앤서` → `answer` in the glossary, `앤서니가 왔어` ("Anthony came") becomes `answer니가 왔어`. A match must start at a word edge and end at one, optionally across a particle — which keeps `캔버스에` working.
- *No one-syllable entries.* `키` → `key` would rewrite `키보드` as `key보드`.

**Whether it is working**, on demand or once a day via `launchd`:

```
$ python3 review_watch.py --stats
받아쓰기 검수 30건 대기 중

최근 50건 정확도 78%
직전 200건 대비 +12%p
등록된 용어 43개
```

It nudges only above a threshold, and at most once per 20 hours. A tool that nags daily gets ignored.

### Privacy

The corpus is recordings and transcripts of **everything you dictate**. Treat it accordingly:

- `corpus/`, `glossary/`, `dictate.log`, and `.dictate_env` are gitignored and created `0600`. Do not relax that.
- `review.py` binds to `127.0.0.1` only.
- **v4 sends transcript text to Google.** Paid-tier Gemini is not used for training, free tier is. Set `DICTATE_FIX=0` for anything you would not send to a third party, or leave the key unset entirely.

---

## What did not work

Four approaches to mixed-language dictation were tried and measured. All four failed, and the measurements are more useful than the code:

| Attempt | Result |
|---|---|
| **Two locales, compare** — run `ko-KR` and `en-US` on the same audio, keep the better one | On Korean audio, `en-US` returns nothing (exit 2). On mixed audio it returns *fluent nonsense* — real output: `Heavenji and silky, ricking, bosu, of, say, in one day, I go, lima.` Because the wrong answer is well-formed, there is no signal for picking a winner. |
| **whisper instead of the Apple engine** — it has better multilingual handling | Inconsistent: emitted `dictation`/`elevator` in English on one clip, left the equivalents in Hangul on another. Introduced a new error (`score` → `school`) the Apple engine got right. `-l auto` translates and summarizes, losing content. Also 1.56s vs 0.35s. |
| **`AnalysisContext.contextualStrings`** — tell the recognizer the vocabulary in advance | The API exists in the macOS 26 SDK and accepts the terms. **It is a no-op.** Output was byte-identical with English terms, with Korean terms (injecting `답안지` did not fix `다반지`), and with deliberate junk (`바나나`, `헬리콥터`). Not "does not work for English" — does not work. |
| **Fine-tuning on the correction log** | The log's "after" values are model output, not verified truth, so training on them compounds the corrector's errors. The failures are vocabulary, not style, and vocabulary belongs in a lookup table you can edit in one line. |

The one that worked — a glossary built from human-confirmed corrections — is also the cheapest and the only one you can debug by opening a text file.

> Spike before you build. `contextualStrings` was going to be the destination for two weeks of corpus collection. Thirty minutes of testing it with ten terms showed it does nothing.

---

## Install

```bash
git clone https://github.com/sunjinpak/hammerspoon-dictation.git
cd hammerspoon-dictation
./install.sh                  # v3 (default, macOS 26+)
./install.sh --version=v1     # v1 (macOS 12+, needs a whisper model)
```

**v4** is v3 plus three files. Copy `v4/*` over your install, then:

```bash
cp v4/.dictate_env.example .dictate_env   # add your Gemini key
chmod 600 .dictate_env
mkdir -p glossary && cp v4/terms.example.tsv glossary/terms.tsv
```

Without `.dictate_env` the correction stage is skipped and you get v3 behavior.

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
| `DICTATE_DEBUG` | `0` | Set to `1` to log to `dictate.log`. **Logs full transcripts** — the file is created `0600` and rotated at 1 MB. |
| `DICTATE_FIX` | `1` | v4. Set to `0` to skip correction for a sensitive utterance. |
| `DICTATE_FIX_MODEL` | `gemini-3.1-flash-lite` | v4. Cheapest tier is right here; a bigger model adds latency, not accuracy, for term restoration. |
| `DICTATE_FIX_TIMEOUT` | `3.0` | v4. Network timeout; a hard SIGALRM backstop fires at +3s. |
| `DICTATE_CORPUS_SAMPLE` | `20` | v4. Keep 1-in-N unchanged utterances for review. |
| `DICTATE_CORPUS_OFF` | `0` | v4. Set to `1` to collect nothing. |
| `DICTATE_NOTIFY` | — | v4. Executable taking the nudge message as `$1`. Prints to stdout if unset. |

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
