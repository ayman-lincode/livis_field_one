# Lincode FIELD ONE — Vision Inspection

An iOS app that puts a Core ML object detector over the live video from an
**ENDLESSRIVER FIELD ONE** wearable inspection camera, and saves the frame the
operator captures with the boxes burnt into it.

Built on the ENDLESSRIVER FIELD ONE iOS SDK 1.1.0 client package that sits
beside this folder. Styled with IBM Carbon (Gray 100 theme) and the Lincode
brand mark.

---

## What it does

| Screen | What it is for |
| --- | --- |
| **Live** | Live video, detection boxes drawn over it, telemetry, and the shutter. |
| **Models** | Import, inspect, name and select Core ML detectors and their labels. |
| **Captures** | Every saved frame, with its detection record, share and export. |
| **Device** | Battery, storage, identity and firmware capabilities read from the camera. |
| **Settings** | Thresholds, input fitting, compute unit, overlay options, connection. |

### Video sources

- **FIELD ONE** — the SDK joins the camera Wi-Fi (optional), discovers the
  camera by RTSP reachability, and plays the stream through the SDK's own
  VLCKit view.
- **This iPhone** — the built-in camera, through AVFoundation. Present so a
  model can be validated on the bench before the hardware is to hand.

### Inference

Frames are offered to the model at a rate you choose (default 10 fps). A frame
that arrives while the previous one is still running is dropped, never queued,
so the overlay always shows the newest result the device could produce.

The app reads four detector output shapes without being told which is which:

| Output | Read as |
| --- | --- |
| `VNRecognizedObjectObservation` | Vision decoded it; used directly |
| `[1, 4+C, A]` / `[1, A, 4+C]` | YOLO v8 / v9 / v10 / v11 |
| `[1, 5+C, A]` / `[1, A, 5+C]` | YOLO v5 / v7, objectness in channel 4 |
| `confidence` + `coordinates` | a CoreML NMS pipeline |

Boxes in pixel units of the model input are detected and rescaled to 0...1.
Non-maximum suppression runs per class.

### Labels

Class names are taken from the model when it carries them: a classifier's
`classLabels`, or the `names` entry Ultralytics writes into user-defined
metadata. Otherwise import a label file from the model row — newline text,
a JSON array, a JSON index-to-name object, or the `names:` block of an
Ultralytics `data.yaml`.

### Capture

The shutter takes a fresh full-quality still, runs the model over exactly those
pixels, then writes three things:

- the annotated JPEG, with boxes, labels and an optional metadata footer
- the unannotated original JPEG
- a JSON record of every detection, in normalised coordinates

so the saved evidence and the saved measurements always agree.

---

## Build and run

```bash
open LincodeFieldOne.xcodeproj
```

Select an iPhone and run. On first open Xcode resolves two packages: the local
`FieldOneSDK` next door, and VLCKit `4.0.0-a22` from VideoLAN. The VLCKit
binary is about 2.6 GB, so the first resolve takes a while and needs access to
GitHub and VideoLAN's download service.

From the command line, reusing the package cache already resolved in `.spm`
so VLCKit is not downloaded a second time:

```bash
xcodebuild -project LincodeFieldOne.xcodeproj -scheme LincodeFieldOne -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -clonedSourcePackagesDirPath ./.spm -derivedDataPath ./.build build
```

Opening the project in Xcode instead resolves into Xcode's own DerivedData, so
that first open downloads VLCKit again. Both `.spm` and `.build` are ignored by
git and safe to delete.

Minimum iOS 17. Camera work needs a physical iPhone: the simulator has no
camera and cannot reach the FIELD ONE Wi-Fi.

### First run with the camera

1. Power on FIELD ONE and let it broadcast its Wi-Fi.
2. Either join that network in iOS Settings, or turn on **Join camera Wi-Fi
   automatically** in the app's Settings and let the SDK prompt.
3. Open **Live** and press **Connect**. The app reports *Camera ready* only
   once a decoded frame has actually arrived, not when the phone joins the SSID.
4. Import a model on **Models**, then return to **Live**.

---

## Verifying without hardware

`Tools/Verify/run.sh` compiles the app's own decoding sources on the Mac and
runs them against both hand-built tensors and a real compiled Core ML model:

```bash
./Tools/Verify/run.sh
```

It checks label parsing in every accepted format, layout detection for the YOLO
v5 and v8 tensor shapes, centre-form to corner-form box conversion, pixel-unit
rescaling, per-class NMS, and a full compile-and-predict round trip.

`Tools/SampleModel/QuadrantSmokeTest.mlpackage` is a small deterministic
detector used by those checks and useful on device: it reports one box per
image quadrant with the confidence of each set to that quadrant's brightness,
so pointing the camera at a lamp lights up a predictable box. Import it from
**Models**, and `Tools/SampleModel/labels.txt` if you want to exercise the
label-import path. `make_quadrant_smoke_test.py` rebuilds it.

Debug builds accept `-startTab <live|models|captures|device|settings>` so each
screen can be screenshotted without touch input.

---

## Known boundaries

**Frame rate on FIELD ONE.** VLCKit exposes no pixel-buffer callback, so the
only way to reach a decoded frame is its snapshot API. The app requests a
reduced-width snapshot on a timer and feeds that to the model. Expect roughly
8-12 frames per second offered to the detector on FIELD ONE, against 15-30 on
the iPhone camera where real pixel buffers are available. Video playback itself
is unaffected and stays at the stream's own rate.

**Capture resolution.** The shutter saves the current live frame at 1280x720,
which is what stock FIELD ONE firmware offers. A 3840x2160 still can only be
recovered from a *closed* recording on the camera's card and is not a
present-moment shutter. The app keeps that distinction in the capture record
and on screen, as the SDK requires. Immediate camera-quality JPEG is gated on
firmware advertising `presentMomentCameraJPEG`, which stock firmware does not.

**Box alignment.** If boxes look offset or squashed, the model was probably
trained with a different input fitting. Change **How the frame is fed to the
model** in Settings: *Stretch* matches most YOLO exports, *Letterbox* matches
letterboxed training, *Centre crop* inspects only the middle square.

---

## Licensing

The optional video module uses VLCKit `4.0.0-a22` under LGPL 2.1-or-later.
Review `Documentation/THIRD_PARTY_NOTICES.md` in the SDK package and satisfy
the applicable obligations before distributing this app.

---

## Layout

```
LincodeFieldOne/
  App/          app entry, root navigation, persisted settings
  Design/       Carbon tokens, components, the Lincode mark and its SVG parser
  Sources/      frame sources: FIELD ONE over the SDK, and the iPhone camera
  Vision/       model store, label parsing, tensor decoding, the detector
  Capture/      annotated-frame compositor and the capture store
  Features/     Live, Models, Gallery, Device, Settings
  Support/      Info.plist and the asset catalogue
Tools/
  SampleModel/  the smoke-test detector and the script that builds it
  Verify/       Mac-side checks over the app's own inference sources
```
