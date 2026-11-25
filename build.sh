#!/bin/zsh
set -euo pipefail

APP_NAME="PinnedTextWidget"
APP_BUNDLE="${APP_NAME}.app"
STAGE_DIR="$(mktemp -d)"
STAGE_BUNDLE="${STAGE_DIR}/${APP_BUNDLE}"
MACOS_DIR="${STAGE_BUNDLE}/Contents/MacOS"
RESOURCES_DIR="${STAGE_BUNDLE}/Contents/Resources"

mkdir -p "${MACOS_DIR}" "${RESOURCES_DIR}"
cp -X Info.plist "${STAGE_BUNDLE}/Contents/Info.plist"

ARCH="$(uname -m)"
swiftc -O -target "${ARCH}-apple-macosx13.0" -framework Cocoa -framework CoreGraphics -framework CoreAudio main.swift -o "${MACOS_DIR}/${APP_NAME}"
xattr -cr "${STAGE_BUNDLE}"
codesign --force --deep --sign - "${STAGE_BUNDLE}"

rm -rf "${APP_BUNDLE}"
ditto --noextattr "${STAGE_BUNDLE}" "${APP_BUNDLE}"
rm -rf "${STAGE_DIR}"

echo "Built ${APP_BUNDLE} successfully."
