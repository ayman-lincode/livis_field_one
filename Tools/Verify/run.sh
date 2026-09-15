#!/bin/sh
# Runs the inference-path checks on this Mac, against the app's own source
# files: tensor decoding, labels, camera JPEG decoding, full-resolution
# inference and the capture record format. No simulator or FIELD ONE needed.
set -e
cd "$(dirname "$0")"
SRC="../../LincodeFieldOne"
swiftc -O -o verify VerifyInferencePath.swift VerifyCapturePath.swift \
  "$SRC/Vision/Detector.swift" \
  "$SRC/Sources/VideoFrame.swift" \
  "$SRC/Sources/FrameSourceKind.swift" \
  "$SRC/Capture/CapturedStill.swift" \
  "$SRC/Capture/CaptureRecord.swift" \
  "$SRC/Vision/DetectionDecoder.swift" \
  "$SRC/Vision/Detection.swift" \
  "$SRC/Vision/LabelSet.swift" \
  "$SRC/Vision/ModelStore.swift" \
  "$SRC/Design/CarbonTheme.swift" \
  "$SRC/Design/CarbonPalette.swift"
./verify
