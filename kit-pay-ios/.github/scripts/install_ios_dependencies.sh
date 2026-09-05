#!/usr/bin/env bash
set -euo pipefail

# Podfile pins the libsignal Git revision and FFI archive checksum. Its build
# phase rehashes the cached archive before use; never cache extracted binaries.
git diff --exit-code --quiet HEAD -- .
pod install

reviewed='KitPay.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved'
resolved='KitPay.xcworkspace/xcshareddata/swiftpm/Package.resolved'
mkdir -p "$(dirname "$resolved")"
cp "$reviewed" "$resolved"
cp "$reviewed" "$RUNNER_TEMP/KitPay-expected-Package.resolved"
xcodebuild -resolvePackageDependencies \
  -workspace KitPay.xcworkspace -scheme KitPay \
  -clonedSourcePackagesDirPath "$RUNNER_TEMP/KitPayPackages" \
  -onlyUsePackageVersionsFromResolvedFile

python3 - "$resolved" "$RUNNER_TEMP/KitPay-expected-Package.resolved" "$reviewed" <<'PY'
import json
import hashlib
import os
import subprocess
import sys
from pathlib import Path

def pins(path):
    return sorted(json.loads(Path(path).read_text())['pins'], key=lambda pin: pin['identity'])

if pins(sys.argv[1]) != pins(sys.argv[2]) or pins(sys.argv[3]) != pins(sys.argv[2]):
    raise SystemExit('Dependency resolution changed the reviewed package pins')

# CocoaPods integrates its generated references into the app project. Record
# exactly that prepared state; later capture provenance rejects further edits.
generated_paths = ('KitPay.xcodeproj/project.pbxproj', sys.argv[3])
changed = subprocess.check_output(['git', 'diff', '--name-only', '-z', 'HEAD']).decode().split('\0')
if any(path and path not in generated_paths for path in changed):
    raise SystemExit('Dependency setup changed unexpected tracked source inputs')
receipt = {
    'sourceCommit': subprocess.check_output(['git', 'rev-parse', 'HEAD'], text=True).strip(),
    'generatedInputs': {path: hashlib.sha256(Path(path).read_bytes()).hexdigest() for path in generated_paths},
}
output = Path(os.environ['RUNNER_TEMP']) / 'KitPay-prepared-native-inputs.json'
output.write_text(json.dumps(receipt, sort_keys=True) + '\n')
output.chmod(0o600)
PY
