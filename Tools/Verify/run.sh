#!/bin/sh
# Runs the inference-path checks on this Mac, against the app's own source
# files. No simulator and no FIELD ONE hardware needed.
set -e
cd "$(dirname "$0")"
SRC="../../LincodeFieldOne"
swiftc -O -o verify VerifyInferencePath.swift \
  "$SRC/Vision/DetectionDecoder.swift" \
  "$SRC/Vision/Detection.swift" \
  "$SRC/Vision/LabelSet.swift" \
  "$SRC/Vision/ModelStore.swift" \
  "$SRC/Design/CarbonTheme.swift" \
  "$SRC/Design/CarbonPalette.swift"
./verify
