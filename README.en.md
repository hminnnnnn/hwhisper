<p align="center">
  <img src="assets/AppIcon-preview.png" width="128" alt="hwhisper icon">
</p>

<h1 align="center">hwhisper</h1>

<p align="center">
  <b>Just speak — typing it out is my job.</b><br>
  A free, open-source, privacy-first alternative to Wispr Flow / Typeless · macOS dictation app
</p>

<p align="center">
  <a href="https://github.com/hminnnnnn/hwhisper/releases/latest"><img src="https://img.shields.io/github/v/release/hminnnnnn/hwhisper?label=release&color=46B99C" alt="Latest release"></a>
  <img src="https://img.shields.io/badge/platform-macOS%2014%2B-lightgrey?logo=apple" alt="Platform: macOS 14+">
  <img src="https://img.shields.io/badge/Swift-6.0-F05138?logo=swift&logoColor=white" alt="Swift 6.0">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-blue" alt="License: MIT"></a>
  <img src="https://img.shields.io/badge/voice-on--device-46B99C" alt="On-device voice">
</p>

<p align="center">
  English (this document) · <a href="README.md">한국어</a>
</p>

<p align="center">
  <img src="assets/demo.gif" width="600" alt="hwhisper demo — onboarding, settings, dictation indicator">
</p>

---

Press a global hotkey and talk. Your **voice never leaves the device** — it's transcribed to Korean/English on-device, optionally polished by an LLM, and **inserted right at your cursor**. Unlike Wispr Flow / Typeless, which send your audio to the cloud, hwhisper does all speech recognition locally on your Mac.

## Features

- **On-device dictation** — Apple `SpeechTranscriber` (Korean CER 1.9%) turns speech into text without leaving the machine. Single-key toggle (Right-⌘ / Right-⌥ / fn) or a key combo.
- **LLM refinement** — filler removal, punctuation fixes, restructuring. Choose Gemini/Groq (free tier), local Ollama, or a custom endpoint. Always optional; falls back to the raw transcript on any failure.
- **Personal dictionary** — register names/terms you often get wrong and they come out right across recognition, refinement, and a final substitution pass.
- **History** — everything you dictate (raw + refined) is stored, searchable, and copyable, on this Mac only. Clearable anytime.
- **Home dashboard** — this week's dictation time, word count, time saved, and per-app usage.
- **Free and unlimited** — no subscription, no word cap. Works with a free refinement API key (or none at all).

## Requirements

- **Apple speech engine (default):** macOS 26 (Tahoe) or later **+ Apple Silicon (M1 or newer)**. Apple `SpeechTranscriber` relies on the Neural Engine, so it is **not** available on Intel Macs.
- **Older / Intel Macs:** a WhisperKit fallback path is planned (needs a model download and more memory).
- **Building from source:** Xcode Command Line Tools (`xcode-select --install`) — the full Xcode is not required.

## Install

### Option A — the released `.dmg` (recommended)

1. Download `hwhisper-x.y.z.dmg` from Releases and open it.
2. Drag `Hwhisper.app` into your `Applications` folder.
3. **First launch (important):** this is a personal/open-source build that is **not** notarized with a paid Apple developer certificate, so macOS Gatekeeper blocks it the first time. Allow it once, either way:
   - **One terminal command (most reliable):**
     ```bash
     xattr -dr com.apple.quarantine /Applications/Hwhisper.app
     ```
   - **Or via System Settings:** try to open the app once → you'll get a blocked notice → go to **System Settings > Privacy & Security** and click "Open Anyway" near the bottom. (Since macOS 15 Sequoia, the old Control-click → Open bypass no longer works.)

> Why is this needed? Opening with no Gatekeeper warning requires notarizing through the paid Apple Developer Program ($99/yr). As a non-commercial open-source project, hwhisper ships without it and asks for this one-time approval instead. If you'd rather not, build it yourself (Option B) — a self-built app skips this step entirely.

### Option B — build from source

To produce a double-clickable `.app` bundle, run this from the repo root:

```bash
bash scripts/make-app.sh
```

It builds a release binary with `swift build -c release`, assembles `dist/Hwhisper.app`, and code-signs it. A self-built app has no quarantine attribute, so it skips the first-launch approval above. Then:

```bash
open dist/Hwhisper.app                    # run it directly
cp -R dist/Hwhisper.app /Applications/    # or install and launch from Launchpad/Spotlight
```

To build a `.dmg` yourself, run `bash scripts/make-dmg.sh` (produces `dist/hwhisper-<version>.dmg`).

## Step-by-step install guide (for an AI assistant to follow)

> This section is written so a person can follow it directly, or an AI assistant (e.g. Claude) can walk a user through it one step at a time. Each step is **decision → command → how to confirm**. Ask the user for command output to decide the next step.

### Step 0 — check the environment (it branches the install path)

Run in the user's terminal and read the output:

```bash
sw_vers -productVersion   # macOS version (e.g. 26.0, 15.6, 14.7)
uname -m                  # arm64 = Apple Silicon, x86_64 = Intel
```

- **macOS 26+ and `arm64`** → Apple on-device engine (fast, accurate). Best path.
- **macOS 14–15 (or `x86_64` Intel)** → runs, but uses the WhisperKit fallback. Warn up front about the **one-time ~600MB model download** and the **multi-minute first dictation**.
- **Below macOS 14** → unsupported; advise updating.

### Step 1 — get the app (one of two)

**(A) Released .dmg** — most users:

```bash
hdiutil attach ~/Downloads/hwhisper-0.2.0.dmg
cp -R "/Volumes/hwhisper 0.2.0/Hwhisper.app" /Applications/
hdiutil detach "/Volumes/hwhisper 0.2.0"
```

**(B) Build from source** — developers, or to verify trust yourself. Requires `xcode-select --install` (CLT):

```bash
git clone <repo URL> hwhisper && cd hwhisper
bash scripts/make-app.sh
cp -R dist/Hwhisper.app /Applications/
```

> A source-built app has no quarantine attribute, so it **skips Step 2.**

### Step 2 — clear the first-launch block (dmg installs only)

The app isn't notarized, so Gatekeeper blocks the first launch. Run this **once**:

```bash
xattr -dr com.apple.quarantine /Applications/Hwhisper.app
```

Confirm: success if the command returns with no error. (Users who can't use the terminal: try to open the app → **System Settings > Privacy & Security** → "Open Anyway". Since macOS 15 this is the only route — the old Control-click bypass is gone.)

> If `xattr` prints `Permission denied` (a known v0.2.0 issue, fixed in v0.2.1), prefix it with `sudo`: `sudo xattr -dr com.apple.quarantine /Applications/Hwhisper.app`. That error only hits a few non-essential files, and the app's own quarantine is usually already cleared, so it often just launches anyway.

### Step 3 — launch

```bash
open /Applications/Hwhisper.app
```

Confirm: a **waveform (🎙) icon appears in the menu bar** (top-right). There is no Dock icon (menu-bar-only app). If nothing appears, see Troubleshooting.

### Step 4 — grant permissions + onboarding

A setup wizard appears on first launch. Grant both permissions; direct paths:

- **Microphone:** System Settings > Privacy & Security > Microphone → enable `Hwhisper`
- **Accessibility (text insertion / global hotkey):** System Settings > Privacy & Security > Accessibility → enable `Hwhisper`

After enabling, fully quit (menu-bar icon > Quit hwhisper) and relaunch to be sure it takes effect.

### Step 5 — verify it works

1. Put the cursor in any text field (Notes, TextEdit, etc.).
2. **Tap Right-⌘ once** → a "listening…" pill appears at the bottom of the screen.
3. Say a sentence, then **tap Right-⌘ again** → the text is inserted at the cursor shortly after.
4. On the WhisperKit path (older Macs), the first run shows "preparing model…" for a few minutes — that's expected.

Diagnose via the log (every step is recorded):

```bash
tail -20 ~/Library/Logs/Hwhisper.log
```

`recording started` → `transcribed N chars` → `insertion outcome: inserted` means it's working.

### Troubleshooting

| Symptom | Cause / fix |
|---|---|
| No menu-bar icon after launch | Usually fine (no Dock icon). Check whether Right-⌘ responds; if still nothing, check `~/Library/Logs/Hwhisper.log` |
| "damaged and can't be opened" | Step 2 `xattr` wasn't run — run it |
| Right-⌘ tap does nothing | Missing Accessibility/Input Monitoring permission. Re-check Step 4, relaunch. You can also switch the hotkey to Right-⌥/fn/combo (menu > Settings) |
| Transcribes but doesn't insert | Accessibility permission issue. On insertion failure the text is preserved to the clipboard — paste with ⌘V |
| No refinement | Refinement is optional. Enable it in Settings and add a free API key. Raw text is inserted regardless |

## Granting permissions on first launch

hwhisper needs microphone access and the Accessibility permission (to type text into other apps). On first launch a setup wizard walks you through these; you can also grant them directly:

- **Microphone:** System Settings > Privacy & Security > Microphone → check `Hwhisper`
- **Accessibility (text insertion / global hotkey):** System Settings > Privacy & Security > Accessibility → check `Hwhisper`

After enabling a permission you may need to fully quit (menu-bar icon > Quit hwhisper) and relaunch for it to take effect.

## The hotkey

A default hotkey is seeded on first launch (it never overwrites a value you changed). It works as a **toggle**: tap once to start recording, tap again to stop — transcription and insertion run immediately. You don't hold it down. While recording, a small pill appears at the bottom-center of the screen showing a live level meter; tap its **✕** to cancel at any time. To change the hotkey, open the menu-bar 🎙 menu > **Settings** and record a new one.

## Refinement setup

On top of the raw transcript, an LLM can remove filler words, fix punctuation/spacing, and smooth the text. **Refinement is always optional and falls back to the raw transcript on any failure or timeout** — it can never block dictation itself.

Configure it in menu-bar 🎙 > **Settings** > **Text Refinement**:

1. Toggle **refinement on**.
2. Pick a **style** — *polish* (filler removal + punctuation only) or *structure* (also turns lists into numbered items and splits topics into paragraphs).
3. Pick a **provider** (one OpenAI-compatible chat-completions client covers all):
   - **Gemini** — free API key: https://aistudio.google.com/apikey (default model `gemini-3.1-flash-lite`)
   - **Groq** — free API key: https://console.groq.com/keys (default model `llama-3.3-70b-versatile`)
   - **Ollama (local)** — no API key, fully offline (default model `qwen2.5:3b`); see below.
   - **Custom** — any OpenAI-compatible `/chat/completions` endpoint URL.
4. Optionally change the **model name** from the preset default.
5. For Gemini/Groq/custom, enter an **API key**. **Keys are stored in `~/Library/Application Support/Hwhisper/credentials.json`, not UserDefaults or the Keychain** (per-provider, owner-only `0600` file in a `0700` folder — the same approach `gh`/`aws`/`gcloud` use; the disk itself is encrypted by FileVault). Ollama needs no key.
6. Set a **timeout** (default 8s); if refinement doesn't finish in time, the raw text is inserted instead.

**Privacy:** with refinement on, only the polished **text** is sent to your chosen provider (a custom provider must be `https://` or local `localhost` — cleartext is refused). **Audio is never sent anywhere** — speech recognition always finishes on-device. Note that text insertion uses clipboard + ⌘V by default, so the transcript briefly passes through the system clipboard during insertion (it is never written to the clipboard when a secure input field is focused).

### Fully local refinement with Ollama

To refine with no API key and no network, install Ollama locally:

```bash
brew install ollama
ollama serve &          # skip if already running (check with curl http://localhost:11434)
ollama pull qwen2.5:3b  # smallest model that handles Korean refinement well (~2.2GB)
```

Then pick **Ollama (local)** as the provider. Note: on an 8GB machine, keeping qwen2.5:3b resident costs ~2.2GB and can cause swap pressure — if memory is tight, prefer a free cloud provider (Gemini/Groq).

## Recognition language

Under Settings > **Recognition Language** you can choose Korean (default) / English / Auto. If English speech keeps being misheard as Korean, switch to **English**. **Auto** currently prioritizes Korean — full in-sentence language switching/detection isn't supported yet.

## Logs

The app appends a log to `~/Library/Logs/Hwhisper.log` (even when launched via `open`). If the hotkey doesn't respond or dictation fails, this file tells you why (missing permission, audio-engine error, recognizer error, etc.).

```bash
tail -f ~/Library/Logs/Hwhisper.log
```

## Launch at login

Use macOS's built-in login items:

1. Copy `Hwhisper.app` to `/Applications`.
2. System Settings > General > Login Items → add `Hwhisper` with `+`.

## Stable code signing (avoid permission resets)

Ad-hoc signing (the default without a certificate) changes the signing identity on every rebuild, which makes macOS re-request already-granted Microphone/Accessibility permissions. To avoid this, create a self-signed certificate ("hwhisper-dev") once that stays constant across rebuilds:

1. Create the cert and import it into your login keychain:
   ```bash
   bash scripts/make-signing-cert.sh
   ```
2. **Manual step (macOS requires a UI confirmation):** open Keychain Access, select the **login** keychain > **My Certificates**, double-click `hwhisper-dev`, expand **Trust**, and set **Code Signing** to **Always Trust**. Close the panel (enter your account password if asked).
3. Rebuild with `bash scripts/make-app.sh` — it detects `hwhisper-dev` and signs with it ("Signing with stable identity: hwhisper-dev"). Without the cert it falls back to ad-hoc signing.

After this one-time setup, rebuilds no longer re-request permissions.

## Known limitations

- **Ad-hoc signing (default without a certificate):** `scripts/make-app.sh` falls back to ad-hoc signing if the `hwhisper-dev` cert above isn't present, so rebuilds may re-trigger permission prompts. See "Stable code signing".
- **Speech engine:** macOS 26+ (Apple Silicon) uses Apple `SpeechTranscriber` (on-device). Older macOS automatically falls back to WhisperKit — this needs a **one-time model download (~600MB)**, uses more memory, and the **first dictation after launch can take a few minutes** (model load + first-run CoreML compilation; fast afterward within the same run). A "preparing model…" indicator shows during this.
- **Network:** the default path (raw dictation) is fully offline after initial asset setup. Refinement's network use depends on the provider (cloud BYOK vs local LLM).

## For developers

To distribute the app yourself, see `docs/RELEASING.md` — it covers both the free track (self-signed dmg, available now) and the notarized track (Developer ID signing → notarization → stapling → Sparkle auto-update).

### Regenerating benchmark fixtures

The speech fixtures used by the engine-comparison harness (`Sources/HwhisperEval`, `fixtures/audio/*.wav`) are large and not committed. Regenerate them from `fixtures/sentences.json` with one command (no extra install — uses macOS's built-in `say`/`afconvert`):

```bash
python3 fixtures/generate_fixtures.py
```

Note: this audio is TTS-synthesized, so the bake-off is a *relative* engine comparison, not a real-world accuracy certification.

## License

[MIT](LICENSE) — Copyright (c) 2026 hminn
