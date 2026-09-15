# Lincode FIELD ONE — Vision Inspection

An iOS app that puts a Core ML object detector over the live video from an
**ENDLESSRIVER FIELD ONE** wearable inspection camera, and saves the frame the
operator captures with the boxes burnt into it.

Built on the ENDLESSRIVER FIELD ONE iOS SDK **1.3.0** client package that sits
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

### Importing a model

Pick any of these from **Models > Import**:

| You pick | What happens |
| --- | --- |
| `.mlpackage` or `.mlmodel` | Compiled on the device |
| `.mlmodelc` | Used as is |
| `.zip` of any of the above | Unpacked in the app, then as above |
| A folder holding a model | Searched for the one model inside |

Zips exported from Python or Colab often hold a package's *contents* at the
root, with no enclosing `.mlpackage` folder. Finder then unpacks them into a
folder named like `best_coreml.mlpackage (1)`, which Core ML does not recognise.
The app spots that layout by its `Manifest.json` and `Data/com.apple.CoreML`
folder, restores the `.mlpackage` extension, and names the model `best_coreml`.
Either the zip or that unpacked folder can be imported.

The unzipper streams each file to disk, so large weight files never sit in
memory. It handles deflated and stored entries, Zip64 and trailing data
descriptors, and skips `__MACOSX` resource forks. It refuses password-protected
zips, paths that climb out of the unpack folder, damaged data that fails its
checksum, and zips that hold more than one model.

### Labels

Class names are taken from the model when it carries them: a classifier's
`classLabels`, or the `names` entry Ultralytics writes into user-defined
metadata. A label file zipped beside the model (`labels.txt`, `classes.txt`,
`data.yaml`, `labels.json` or a `.names` file) is used when the model carries
none. Otherwise import a label file from the model row — newline text,
a JSON array, a JSON index-to-name object, or the `names:` block of an
Ultralytics `data.yaml`.

### Capture

On FIELD ONE the shutter takes a **camera photo**, not a frame of the video:

1. The SDK's `captureHighQualityNow(output: .bytes, preview:)` stops the preview,
   switches the camera to still mode, restarts the preview and fires the shutter.
   The app passes the retained preview-lifecycle adapter, as the SDK requires.
2. The camera's JPEG comes back as its original bytes, at whatever image size is
   set on the camera. The SDK validation record measured 3840x2160; the vendor
   trace reported 4216x2376. The app reads the size from the photo itself.
3. The JPEG is decoded upright at full resolution and the model runs on that
   whole still. Live inference pauses while this happens.
4. The result opens straight away: the photo with its boxes, zoomable, with the
   detections and the camera's metadata underneath.

Each capture is saved as three files:

- the camera's original JPEG, byte for byte
- an annotated JPEG, with boxes, labels and an optional metadata footer
- a JSON record of every detection in normalised coordinates, the provenance,
  and the camera's file name, handle, JPEG size and shutter-to-download time

The shutter reads **PHOTO** when a camera photo will be taken. It reads **FRAME**
when it can only save the live 1280x720 frame: no usable card, firmware that does
not advertise `presentMomentCameraJPEG`, or camera control not responding. That
fallback is labelled as a live frame everywhere it appears.

Photo failures follow the SDK's guidance. A photo during camera recording shows
"Stop recording to take an image." A timed-out or interrupted photo warns that
the camera may already have saved it, and the app never fires a second shutter
on its own. A camera cooldown blocks the shutter until it expires.

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

Minimum iOS 17; SDK 1.3.0 itself needs iOS 16. Camera work needs a physical iPhone: the simulator has no
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
rescaling, per-class NMS, and a full compile-and-predict round trip. For the
camera-photo path it decodes a 4216x2376 JPEG with and without EXIF rotation,
runs the app's own `Detector` on the full still with stretch and letterbox
fitting, and confirms capture records from earlier builds still load.

For model import it builds zips in every shape the importer must handle and
runs each result through the detector: contents at the root, a Finder zip with
`__MACOSX`, stored entries, Zip64, data descriptors, and an unzipped folder with
a duplicate name. It also confirms zip-slip paths, two-model zips and damaged
data are refused. Point it at your own zip to import and run that too:

```bash
MODEL_ZIP="/path/to/best_coreml.mlpackage.zip" ./Tools/Verify/run.sh
```

`Tools/SampleModel/QuadrantSmokeTest.mlpackage` is a small deterministic
detector used by those checks and useful on device: it reports one box per
image quadrant with the confidence of each set to that quadrant's brightness,
so pointing the camera at a lamp lights up a predictable box. Import it from
**Models**, and `Tools/SampleModel/labels.txt` if you want to exercise the
label-import path. `make_quadrant_smoke_test.py` rebuilds it.

Debug builds accept `-startTab <live|models|captures|device|settings>`, and
`-reviewLatestCapture` alongside `-startTab captures`, so each screen can be
screenshotted without touch input.

---

## Known boundaries

**Frame rate on FIELD ONE.** VLCKit exposes no pixel-buffer callback, so the
only way to reach a decoded frame is its snapshot API. The app requests a
reduced-width snapshot on a timer and feeds that to the model. Expect roughly
8-12 frames per second offered to the detector on FIELD ONE, against 15-30 on
the iPhone camera where real pixel buffers are available. Video playback itself
is unaffected and stays at the stream's own rate.

**Camera photo hardware status.** The SDK 1.3.0 validation record lists the
final hardware retest of bytes output as still open. Its earlier phone run of the
same capture sequence produced decodable 3840x2160 JPEGs in 1.7 to 3.9 seconds.
Treat the first on-device photos from this app as that acceptance check.

**Provenance.** Camera photos, live preview frames and frames recovered from
closed recordings are recorded and labelled separately, as the SDK requires.

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
