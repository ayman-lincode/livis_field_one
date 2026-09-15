#!/bin/sh
# Runs the inference-path checks on this Mac, against the app's own source
# files: tensor decoding, labels, camera JPEG decoding, full-resolution
# inference, the capture record format and zipped model import.
# Set MODEL_ZIP=/path/to/model.zip to also import and run your own model.
# No simulator or FIELD ONE needed.
set -e
cd "$(dirname "$0")"
SRC="../../LincodeFieldOne"
export ZIP_FIXTURES="${TMPDIR:-/tmp}/lincode-zip-fixtures"
python3 make_zip_fixtures.py "$ZIP_FIXTURES"
swiftc -O -o verify VerifyInferencePath.swift VerifyCapturePath.swift VerifyModelArchive.swift \
  "$SRC/Vision/ModelArchive.swift" \
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
