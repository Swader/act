#!/bin/bash
# Builds build/Act.app and build/com.brunoskvorc.act.helper.
set -euo pipefail
cd "$(dirname "$0")"

rm -rf build
mkdir -p build/Act.app/Contents/MacOS
swiftc -O -swift-version 6 -o build/com.brunoskvorc.act.helper Sources/Helper/*.swift Sources/Shared/*.swift
swiftc -O -swift-version 6 -o build/Act.app/Contents/MacOS/Act Sources/App/*.swift Sources/Shared/*.swift
cp Resources/Info.plist build/Act.app/Contents/
codesign --force --sign - --identifier com.brunoskvorc.act.helper build/com.brunoskvorc.act.helper
codesign --force --sign - build/Act.app
