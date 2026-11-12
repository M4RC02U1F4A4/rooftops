#!/bin/sh
# Builds Snow.app (menu-bar only, no Dock icon). Run: ./build.sh && open Snow.app
set -e
cd "$(dirname "$0")"
mkdir -p Snow.app/Contents/MacOS
swiftc -O Snow.swift -o Snow.app/Contents/MacOS/Snow
cat > Snow.app/Contents/Info.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>local.snow</string>
  <key>CFBundleName</key><string>Snow</string>
  <key>CFBundleExecutable</key><string>Snow</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSUIElement</key><true/>
  <key>NSLocationUsageDescription</key><string>Snow usa la tua posizione per mostrare il meteo del posto in cui ti trovi.</string>
  <key>NSLocationWhenInUseUsageDescription</key><string>Snow usa la tua posizione per mostrare il meteo del posto in cui ti trovi.</string>
</dict></plist>
PLIST
codesign --force --sign - Snow.app
