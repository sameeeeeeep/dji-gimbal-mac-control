# Gimbal Controller

Control your DJI Osmo Mobile gimbal from your Mac using BLE. Uses Apple Vision for face/person tracking, on-device speech detection for speaker follow, and equirectangular panorama stitching to build a live 360° map of the room.

## Features

### Camera Tracking
- **Face & person tracking** — Vision framework detects subjects and keeps them centred via proportional speed control with EMA smoothing
- **Open-palm gesture** — hold up an open hand to redirect the gimbal toward you, even mid-session
- **Follow Mode** — persists across tab navigation; gimbal keeps tracking even when you switch views

### Room Scan & Panorama
- **5-row serpentine scan** — gimbal sweeps the full room at five pitch levels (+28°, +14°, 0°, −14°, −28°), covering standing and seated people
- **Equirectangular panorama** — every frame during the scan is tagged with the exact gimbal angle and stitched into a 2048×1024 panorama using known-pose projection (no feature matching needed)
- **Interactive 360° sphere** — after the scan, the panorama wraps a SceneKit sphere; drag to look around, scroll to zoom
- **People pins** — detected people appear as cyan dots at their real angular positions on the sphere; click a dot to send the gimbal there
- **Duplicate suppression** — same person seen across multiple rows is merged with a 40° radius + running-average position refinement
- **Click-to-navigate** — tap any person dot (on sphere or in list) to physically rotate the gimbal to that person
- **Name tagging** — assign names to people after the scan; labels appear on the sphere

### Speaker Follow
- **VAD + mouth detection** — identifies who is speaking using RMS audio + lip-movement diarisation
- **Speaker hold** — gimbal stays on the last speaker for 2.5 s after they go silent
- **Voice-triggered search** — if speech is detected but no face is in frame, launches a fast left-right sweep
- **Live captions** — optional on-device Whisper transcription with speaker attribution

### Dot Agent (voice)
- Wake word **"Hey Dot"** — activates the voice agent
- Commands: `wave`, `find me`, `look left/right/up/down`, `center`, `follow me`, `stop`

### Capture
- **Photos** and **video recording** saved to `~/Movies/GimbalCaptures/`

---

## Build & Run

Requires macOS 14+, Xcode Command Line Tools, and a DJI Osmo Mobile gimbal.

```bash
make        # builds release binary, codesigns, copies to ~/Applications
make run    # build + launch immediately
```

No Xcode project — pure `swift build` + Makefile.

---

## Architecture

| File | Role |
|------|------|
| `GimbalService.swift` | BLE orchestrator, DUML packet builder/parser |
| `CameraTracker.swift` | AVFoundation capture, Vision inference, follow loop, room sweep |
| `PanoramaBuilder.swift` | Equirectangular panorama stitcher (CGContext, background thread) |
| `PanoramaSphereView.swift` | SceneKit sphere viewer with drag-to-look and tap-to-navigate |
| `DotAgent.swift` | Voice agent state machine |
| `VoiceListener.swift` | Continuous SFSpeechRecognizer, wake-word detection |

### Room scan pipeline
```
5-row serpentine sweep (speed commands, ~90s)
        ↓
Every 0.35s: capture frame + record gimbal pose
        ↓
After sweep: PanoramaBuilder stitches frames → 2048×1024 equirectangular
        ↓
PanoramaSphereView wraps image onto inside of SCNSphere
        ↓
People pins placed at (yaw, pitch) → 3D Cartesian on sphere surface
        ↓
Tap pin → navigateTo(yaw, pitch) → speed-command navigation with position polling
```

### Why not 3D Gaussian Splat?
The gimbal rotates around a fixed point — all frames share the same optical centre, so there is no parallax and therefore no depth information. True 3DGS / NeRF / SLAM require camera translation. What this app produces is an accurate angular map: every pixel is placed at exactly the right direction, and people are pinned at their correct bearing.
