# GimbalController

A macOS app for controlling a DJI Osmo Mobile gimbal over Bluetooth Low Energy. Built with SwiftUI and compiled directly with `swiftc` via a Makefile — no Xcode required.

## Features

- **Face and person tracking** — Apple Vision (ANE-accelerated) detects faces or full-body silhouettes and drives the gimbal with a proportional-EMA speed controller. Open-palm gesture overrides tracking to reframe onto whoever waves.
- **Speaker follow with diarization** — Fuses VAD (RMS mic level), Vision mouth-aspect-ratio analysis, and WhisperKit + SpeakerKit (pyannote CoreML) to identify and continuously follow the active speaker in a multi-person scene.
- **Room scan and equirectangular panorama** — A 7-column serpentine sweep covers ±135° yaw at ±28° pitch. Captured frames are stitched into a 2048 × 1024 equirectangular panorama using backward projection with cosine-weighted blending. A 360° SceneKit sphere lets you drag to explore the result.
- **AI real-time journal** — Runs MLX Qwen2.5-1.5B-Instruct-4bit in a persistent Python subprocess. Change events (face count, body activity, hand gesture, OCR) trigger a narrative beat written to a Markdown session file in `~/Movies/GimbalCaptures/Journal/`.
- **"Hey Dot" voice agent** — Continuous `SFSpeechRecognizer` listens for the wake phrase. Recognised commands: `wave`, `find me`, `look left/right/up/down`, `center`, `follow me`, `stop`.
- **Live transcription** — WhisperKit transcribes a rolling 30-second audio buffer. SpeakerKit (pyannote CoreML) adds per-speaker attribution so the transcript reads `Speaker 1: …`.
- **Point-and-go navigation** — Tap any location in the panorama sphere to navigate the gimbal there using speed-command dead-reckoning with BLE position polling.
- **Photo and video capture** — Save JPEG stills and MOV recordings to `~/Movies/GimbalCaptures/`.
- **BLE debug panel** — Raw DUML packet log, probe tool for cmdSet/cmdID discovery, write-type toggle (with/without response), and per-characteristic write tool.

## Requirements

- **macOS 13 Ventura or later** (macOS 14 recommended for best ANE performance)
- **DJI Osmo Mobile** (tested on OM6; OM4/OM5 should work)
- **Xcode Command Line Tools** — `xcode-select --install`
- **Homebrew Python 3.11+** for the MLX journal feature (optional):
  ```sh
  brew install python@3.11
  pip install mlx-lm
  ```
  The app writes an inference server script to `~/Library/Application Support/GimbalController/mlx_server.py` on first launch and prefers a venv at `~/Library/Application Support/GimbalController/venv/` before falling back to Homebrew or system Python. All features except the AI journal work without Python.

## Build and Run

```sh
# Build release binary, sign, and install to ~/Applications/
make

# Build and launch immediately
make run

# Run tests
make test

# Clean build artefacts
make clean
```

`make` calls `swift build -c release`, assembles the `.app` bundle, ad-hoc codesigns with the project entitlements, and copies to `~/Applications/`. No Xcode installation is required beyond the Command Line Tools.

On first launch macOS will prompt for Bluetooth, Camera, Microphone, and Speech Recognition permissions. All four are required for full functionality.

## Architecture Overview

```
GimbalService  (@MainActor, ObservableObject)
├── BLEConnectionManager   CoreBluetooth scan/connect/send/receive
├── DUMLPacketBuilder      Assemble DUML frames (CRC8 header, CRC16 body)
├── DUMLPacketParser       Reassemble fragmented BLE notifications
└── CameraTracker          (@MainActor, AVFoundation + Vision)
    ├── SpeakerFollowManager   Real-time VAD (RMS + EMA)
    ├── WhisperTranscriber     WhisperKit + SpeakerKit (pyannote) diarization
    ├── JournalAnalyzer        Change detection → MLXRunner prompt → Markdown
    │   └── MLXRunner          Long-lived Python subprocess, JSON-lines protocol
    └── PanoramaBuilder        Backward-projection equirectangular stitcher
```

**DUML over BLE** — The app speaks the binary framing used by DJI's own apps (documented by the `om-research` project). Each packet starts with `0x55`, carries a length, CRC8-protected header, and CRC16-protected body. Commands are dispatched on BLE service `0xFFF0`, write characteristic `0xFFF5` (speed `cmdSet=0x04 cmdID=0x0C`; angle `cmdSet=0x04 cmdID=0x14`), notify characteristic `0xFFF4`.

**Apple Vision on the ANE** — `VNDetectFaceRectanglesRequest`, `VNDetectFaceLandmarksRequest`, `VNDetectHumanRectanglesRequest`, `VNDetectHumanBodyPoseRequest`, and `VNDetectHumanHandPoseRequest` all run on the Neural Engine via the camera's dedicated background queue. The follow loop drives the gimbal at 30 fps via speed commands; absolute angle commands are used only for scan waypoints and recentering.

**MLX subprocess** — `MLXRunner` launches a Python process that loads Qwen2.5-1.5B-Instruct-4bit via `mlx-lm` and stays warm between requests. Communication is JSON-lines on stdin/stdout. On M1 Air (8 GB), the model loads in ~15 s and generates ~60 narrative tokens in ~4 s.

**WhisperKit transcription** — Audio is captured at 16 kHz mono, accumulated in a rolling buffer (max 2 minutes), and flushed every 30 seconds. WhisperKit and SpeakerKit run concurrently; their outputs are merged with `addSpeakerInfo(to:strategy:subsegment)`. Persistent speaker IDs survive chunk boundaries via a per-session registry.

**Panorama stitching** — Backward projection: for each output pixel compute its world direction (longitude/latitude → 3D unit vector), apply the inverse gimbal rotation (yaw then pitch), project perspectively into the source frame, bilinear-sample, and accumulate with a cosine edge weight `cos((u−0.5)π)·cos((v−0.5)π)`. Output: 2048 × 1024 RGBA8.

## Component Reference

| Component | File | Purpose |
|-----------|------|---------|
| `GimbalService` | `Sources/Gimbal/GimbalService.swift` | Central orchestrator — owns all subsystems, wires callbacks, sends DUML commands |
| `GimbalCommand` | `Sources/Gimbal/GimbalCommand.swift` | Static builders for every DUML payload; angles in 0.1° units, time in 10ms units |
| `DUMLConstants` | `Sources/Protocol/DUMLConstants.swift` | cmdSet/cmdID enums, RotationMode enum |
| `BLEConnectionManager` | `Sources/BLE/BLEConnectionManager.swift` | CoreBluetooth scan, connect, write, notify |
| `CameraTracker` | `Sources/Camera/CameraTracker.swift` | AVFoundation capture, Vision detection, room sweep, follow loop, panorama frame capture |
| `SpeakerFollowManager` | `Sources/Camera/SpeakerFollowManager.swift` | VAD using RMS amplitude with EMA smoothing |
| `WhisperTranscriber` | `Sources/Camera/WhisperTranscriber.swift` | WhisperKit + SpeakerKit live transcription with persistent speaker IDs |
| `JournalAnalyzer` | `Sources/Camera/JournalAnalyzer.swift` | Vision scene analysis, change detection, MLX narrative generation |
| `MLXRunner` | `Sources/Camera/MLXRunner.swift` | Persistent Python subprocess manager, async `query()` API |
| `PanoramaBuilder` | `Sources/Camera/PanoramaBuilder.swift` | 2048×1024 equirectangular stitcher with cosine blending |
| `TrackingView` | `Sources/Views/TrackingView.swift` | Camera preview, detection overlay, speaker follow controls |
| `PanoramaSphereView` | `Sources/Views/PanoramaSphereView.swift` | SceneKit 360° sphere viewer with click-to-navigate |

## Data Storage

All captures are written to `~/Movies/GimbalCaptures/`:

```
~/Movies/GimbalCaptures/
├── Photos/          JPEG stills
├── Videos/          MOV recordings
└── Journal/
    ├── index.md     Links to all sessions
    └── session_YYYYMMDD_HHmmss.md   One narrative file per journal session
```

## Why No Parallax / 3D Reconstruction?

The gimbal rotates around a fixed optical centre — all frames share the same projection point, so there is no parallax and therefore no depth information. True 3DGS / NeRF / SLAM require camera translation. What this app produces is an accurate angular map: every pixel is placed at exactly the right bearing, and people are pinned at their correct angular position in the room.
