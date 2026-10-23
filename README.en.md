# MeetingRecorder

A local-first meeting recorder for macOS: **dual-track audio, on-device transcription, and meeting minutes**.
Your meeting content stays on your Mac by default.

[简体中文](README.md) · [English]

![Main window](docs/screenshots/main-window.png)

---

## What it solves

Four things about online meetings are persistently awkward:

1. **A recording doesn't tell you who spoke.** Most tools give you one mixed file; the moment two people talk at once, the thread is lost.
2. **Transcription means uploading.** Cloud services are cheap and good — but meeting audio is often the last thing you want to hand to a third party.
3. **Nobody writes it up.** A two-hour recording may contain five decisions.
4. **You may not want the recording to be visible.** When you share your screen or a colleague walks past, that timer and red dot in the menu bar are conspicuous — but not recording at all costs more.

One design decision for each:

| Problem | Approach |
|---|---|
| Who said it | **Dual-track recording**: "Me" = microphone, "Them" = system audio output. Speaker identity comes from the **track**, not from voice separation. |
| Uploading | Native macOS speech recognition, running **on device**. Audio never leaves the machine. |
| No write-up | A **minutes layer** on top of the transcript: on-device model by default, or bring your own cloud API. |
| Not wanting it visible | **Recording state can be turned off**: during recording, leave only a neutral icon (no timer, no red tint) — or hide the menu bar icon entirely. Control it with **global hotkeys** instead: ⌥⌘R start / ⌥⌘P pause / ⌥⌘S stop / ⌥⌘M show window. |

The output is a folder of plain files (`manifest.json` / `mic.wav` / `system.wav` / `transcript.md`).
No database — copy it, `grep` it, drop it into any backup.

---

## Features

- **Dual-track recording** — microphone and system audio written to two WAV files, aligned on `hostTime`; both tracks can play together with independent volume
- **Crash recovery** — checkpoints every 5 seconds while recording; `mr recover` sweeps up after an unclean exit
- **On-device transcription** — 30 languages supported by the system engine; long audio in one pass (~160× realtime measured)
- **Optional stronger engine** — SenseVoice (opt-in, ~244 MiB model download), steadier on domain-specific vocabulary
- **Meeting minutes** — restructures the transcript into topics, conclusions, decisions, action items and open issues — and lists the recognition errors it corrected
- **Editable transcript** — fix or clear individual segments; edits are kept alongside the original text
- **Storage controls** — 16-bit integer plus mono/24 kHz bring the files to roughly 1/6 of the default size
- **Menu bar presence** — recording timer in the menu bar, plus a "conceal" mode that leaves only a neutral icon (no timer, no red tint); you can also hide the menu bar icon entirely — **recording is unaffected**. Both switches are in Settings (⌘,) → General → Menu bar
- **Global hotkeys** — ⌥⌘R start / ⌥⌘P pause / ⌥⌘S stop / ⌥⌘M show window, working while any other app is in front. They keep working when the recording state is hidden, so "don't let others see it" never turns into "now I can't control it either"; if another app already owns a combination, you are told instead of silently getting nothing
- **Export** — Markdown / plain text / merge both tracks into one stereo file (me = left, them = right)

---

## Requirements

- **macOS 26.0 or later** (the transcription and on-device model frameworks do not exist earlier)
- Apple Silicon or Intel Mac (**only verified on Apple Silicon** — see Known limitations)
- Xcode command line tools (Swift 5.9+) to build
- Two permissions on first recording: **Microphone** and **Screen & System Audio Recording**

---

## Build and install

```bash
git clone https://github.com/mybigbag/MeetingRecorder.git meeting-recorder
cd meeting-recorder

# 1. Compile and bundle into a .app — required, see below
#    (the script runs `swift build -c release` itself)
./scripts/build-app.sh

# 2. Launch
open MeetingRecorder.app
```

`build-app.sh` writes `MeetingRecorder.app` to the repository root and bumps the
version stamp on every build (`MAJOR.YYYYMMDD.HHMM`). To compile without bundling: `swift build`.

> **Why it has to be a `.app`**
> System-audio capture (Core Audio Process Tap) grants permission per **bundle identity**.
> Running the bare binary from `.build` gets no permission — and fails **silently**:
> every API returns success, sample counts are exactly right, and the buffers are all zeros.
> The `./mr` script at the repo root is a thin wrapper that forwards to the binary inside the `.app`.

If the build fails with `sandbox-exec: Operation not permitted`, add `--disable-sandbox`
to `swift build` / `swift test`.

### Command line entry point

```bash
./mr doctor     # capability check: permissions, engines, devices
./mr --help     # every command and option
```

To use it from anywhere:

```bash
ln -s "$(pwd)/mr" /usr/local/bin/mr
```

---

## Quick start

### GUI

1. Double-click `MeetingRecorder.app` — an icon appears in the menu bar
2. Type a title (optional, auto-generated if empty) and press **Start recording**
3. Press **Stop** when done; you can pause and resume at any point
4. Open the meeting from the sidebar: three sections — audio tracks, minutes, transcript
5. Press **Re-transcribe** if there is no transcript yet, then **Generate minutes**

![Detail view](docs/screenshots/detail-tracks.png)

Only the minutes section is expanded by default: during a meeting you usually want
the conclusions first, and the verbatim transcript when you need to check a quote.

### CLI

```bash
# Record (Ctrl-C to stop)
./mr record --title "Product review"

# Transcribe (session ID from `list`, or pass the directory)
./mr transcribe 2026-10-19-143012-Product-review

# Transcribe and generate minutes in one go
./mr transcribe 2026-10-19-143012-Product-review --minutes

# What have I recorded?
./mr list
```

---

## Storage layout

One folder per meeting, under `~/Documents/MeetingRecorder/` by default (change with `--root`):

```
~/Documents/MeetingRecorder/
└── 2026-10-19-143012-Product-review/
    ├── manifest.json      all metadata (times, devices, formats, pauses, state)
    ├── mic.wav            "Me" track — local microphone
    ├── system.wav         "Them" track — system audio output
    ├── transcript.md      transcript, for humans (timestamps and speakers)
    ├── transcript.json    transcript, for programs
    ├── minutes.md         meeting minutes, for humans
    └── minutes.json       meeting minutes, structured
```

`samples/` contains a **format example** (synthetic content, just to show the fields).

`manifest.json` is the single source of truth for a session: deleting the transcript
does not touch the audio, and deleting `minutes.json` only means the minutes must be regenerated.

---

## Meeting minutes

By default the minutes are produced by the **on-device model** — the transcript never
leaves the machine. If Apple Intelligence is not enabled on your Mac, it degrades
explicitly to "transcript only" rather than pretending to have written minutes.

For stronger output you can point it at any **OpenAI-compatible** endpoint
(DeepSeek, GLM, Qwen, Kimi, …):

```bash
./mr config set minutes api
./mr config set minutes-url https://api.deepseek.com/v1
./mr config set minutes-key sk-...
./mr config set minutes-model deepseek-chat
```

Or fill it in under **Settings (⌘,) → Meeting minutes**, and press **Test connection**
to verify on the spot (it sends one fixed sentence, never meeting content).

> **This is a privacy decision, not a performance switch.** Choosing `api` sends the
> transcript to the address you configured. The key is stored only in local preferences;
> the UI, logs and `config show` mask it; it is never written into `minutes.md` /
> `minutes.json` and never sent with the minutes request.

![Settings](docs/screenshots/settings.png)

---

## Privacy

- **No account, no server, no telemetry.** The tool makes no callbacks.
- **Audio and transcripts stay local by default.** Transcription uses the system
  speech framework, on device.
- **Cloud is optional and must be configured.** If any of the three fields
  (URL / model / key) is missing, generating minutes fails **before writing any file**
  and prints the commands to run. It never falls back silently, and never produces
  a document attributed to the wrong engine.
- **Deletion goes through the Trash.** Pruning removes only `.wav` files;
  the manifest and transcripts are kept.

---

## Command reference

| Command | Purpose |
|---|---|
| `mr record` | Dual-track recording (`--title` / `--seconds` / `--pcm16` / `--mono24k` / `--root`) |
| `mr transcribe <session>` | Transcribe; `--track mic\|system` for a single track, `--minutes` to generate minutes too |
| `mr minutes <session>` | Generate minutes for an already transcribed meeting |
| `mr list` | List all meetings |
| `mr devices` | List audio input devices (with UIDs, for `--device`) |
| `mr recover` | Scan for and repair recordings left behind by a crash |
| `mr doctor` | Capability check: permissions, engines, devices |
| `mr transcode <session>` | Re-encode existing audio into a smaller format (`--all`, `--dry-run`) |
| `mr merge <session>` | Merge both tracks into one stereo file (me = left, them = right) |
| `mr prune` | Delete old audio per the retention policy (the only destructive command; dry-run by default) |
| `mr config` | Read or change global settings (engine, minutes backend, retention, menu bar icon…) |
| `mr model` | Manage SenseVoice assets (download / verify / remove) |
| `mr version` | Print the version |

Full options and rationales live in `./mr --help` — it is longer than most READMEs,
because every flag behind it corresponds to a decision you can get wrong.

**Three easy mistakes:**

```bash
# The transcription engine is a global setting, not a per-meeting choice
./mr config set engine sensevoice
./mr model download           # required first time (~244 MiB)

# "Set a retention policy" and "prune now" are two separate actions:
# setting a policy never deletes anything — it only decides when someone will
./mr config set retention 30
./mr prune --dry-run          # see how many sessions and how much space first
./mr prune --yes              # actually prune
```

---

## Development

### Modules

| Module | Responsibility |
|---|---|
| `MRCore` | Pure logic: WAV, timeline, manifest, transcript model, retention policy. No system dependencies, fully testable without permissions |
| `MRCapture` | Core Audio: microphone + system-audio process tap, disk writing, crash checkpoints |
| `MRTranscribe` | Transcription engines (system speech / SenseVoice) and asset management |
| `MRMinutes` | Minutes layer: chunking, map-reduce orchestration, degradation, cloud API client |
| `MRSession` | Shared orchestration used by both the CLI and the GUI |
| `MRCLI` | Command-line front end: argument parsing and terminal output |
| `MRGUI` | SwiftUI + AppKit: main window, menu bar item, settings window, player |
| `MeetingRecorderMain` | The only `@main`: dispatches to CLI with arguments, to the window without |

### Tests

```bash
swift test                  # full suite (~1300 tests)
swift test --filter MRCoreTests
```

The test split follows the project's own rule: **anything testable as pure logic never
touches the UI**. The audio chain (timeline, WAV, crash recovery) runs on synthetic data
in `MRCoreTests` with no permissions required. Only two things in the UI are unit-tested:
the player state machine, and the switches whose failure is **invisible on screen**
(such as the recording timer under conceal mode).

### Visual review

Assertions are not enough for UI changes. Each probe under `scripts/probes/` mounts the
**production view** in a real `NSWindow`, renders it offscreen with `cacheDisplay(in:to:)`,
and writes a PNG for a human to look at:

```bash
swift build
./scripts/probes/readme-shots/run.sh        # the three images in this README
./scripts/probes/settings-window-render/run.sh
./scripts/probes/meeting-detail-render/run.sh
```

They need no screen-recording permission and never touch your real meeting library
(temp directory + isolated preference domain). `ImageRenderer` is deliberately avoided:
views containing a `ScrollView` do not lay out offscreen and render as a blank block,
while size assertions stay green. That trap was hit twice here.

---

## Known limitations

Measured boundaries, not a to-do list:

- **macOS 26+ only.** The frameworks behind transcription and on-device minutes do not exist earlier.
- **Verified on Apple Silicon only.** Nothing intentionally depends on the architecture,
  but Intel machines are untested — especially system-audio capture.
- **Without Apple Intelligence, minutes degrade to "transcript only".** Expected behaviour,
  clearly labelled in the UI; you will not receive a silently empty document.
- **The menu bar icon must be launched through the system.** Executing the binary inside
  the `.app` directly makes macOS **permanently** refuse to register the status item for
  that bundle (the icon never comes back). Launch from Finder or with `open`; the app also
  hands off automatically, but there is no upside to bypassing it.
- **No speaker diarization.** "Who spoke" comes from the track, so it fits
  "one computer, speakers or headphones". Three people sharing one microphone
  will all be recorded as "Me".
- **The "Them" track depends on system-audio capture.** On some devices/drivers it may
  capture silence; `mr doctor` prints actual sample values to distinguish
  "no sound" from "no permission".
- **No segmentation for long audio.** Two hours transcribe in 56 seconds with flat 24 MB
  memory; segmenting was 5× slower. `--segment` remains for the case where one bad
  chunk must not take down a whole track.

---

## License

[MIT](LICENSE)
