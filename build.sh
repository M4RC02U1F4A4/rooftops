#!/bin/sh
# Builds Rooftops.app (menu-bar only, no Dock icon). Run: ./build.sh && open Rooftops.app
set -e
cd "$(dirname "$0")"
mkdir -p Rooftops.app/Contents/MacOS
swiftc -O Rooftops.swift -o Rooftops.app/Contents/MacOS/Rooftops
cat > Rooftops.app/Contents/Info.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>local.rooftops</string>
  <key>CFBundleName</key><string>Rooftops</string>
  <key>CFBundleExecutable</key><string>Rooftops</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSUIElement</key><true/>
  <key>NSLocationUsageDescription</key><string>Rooftops usa la tua posizione per mostrare il meteo del posto in cui ti trovi.</string>
  <key>NSLocationWhenInUseUsageDescription</key><string>Rooftops usa la tua posizione per mostrare il meteo del posto in cui ti trovi.</string>
</dict></plist>
PLIST
codesign --force --sign - Rooftops.app
