#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build.noindex/Pulse.app/Contents/MacOS build.noindex/Pulse.app/Contents/Resources build.noindex/module-cache
xcrun clang -O2 -mmacosx-version-min=14.0 -c Sources/MonitorBridge.c -o build.noindex/MonitorBridge.o
xcrun swiftc -O -whole-module-optimization -swift-version 5 -target arm64-apple-macosx14.0 \
  -module-cache-path build.noindex/module-cache \
  -import-objc-header Sources/MonitorBridge.h \
  Sources/Metrics.swift Sources/PanelLayout.swift Sources/AccountUsage.swift Sources/Sampler.swift Sources/MonitorModel.swift Sources/PopoverView.swift Sources/HoverCard.swift Sources/Updater.swift Sources/PulseApp.swift \
  build.noindex/MonitorBridge.o -o build.noindex/Pulse.app/Contents/MacOS/Pulse \
  -framework AppKit -framework SwiftUI -framework ServiceManagement -framework UserNotifications
# The commit this build comes from, so the app can tell when GitHub has a newer one.
commit=${PULSE_COMMIT:-$(git rev-parse HEAD 2>/dev/null || true)}
[[ $commit =~ ^[0-9a-f]{40}$ ]] || commit=""
cat > build.noindex/Pulse.app/Contents/Info.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>Pulse</string>
<key>CFBundleIdentifier</key><string>local.koz46.pulse</string>
<key>CFBundleName</key><string>Pulse</string>
<key>CFBundleDisplayName</key><string>Pulse</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.8</string>
<key>CFBundleVersion</key><string>11</string>
<key>PulseCommit</key><string>$commit</string>
<key>CFBundleIconFile</key><string>Pulse</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
cp Integrations/usage_bridge.py build.noindex/Pulse.app/Contents/Resources/usage_bridge.py
xcrun swift -module-cache-path build.noindex/module-cache scripts/make-icons.swift "$PWD"
iconutil -c icns build.noindex/Pulse.iconset -o build.noindex/Pulse.app/Contents/Resources/Pulse.icns
cp Resources/*.png Resources/update.sh build.noindex/Pulse.app/Contents/Resources/
codesign --force --sign - build.noindex/Pulse.app
printf 'Built %s/build.noindex/Pulse.app\n' "$PWD"
