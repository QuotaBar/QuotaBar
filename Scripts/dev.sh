#!/bin/zsh
# Fast dev loop: incremental debug build + run the binary directly.
# No packaging / codesign / icns — rebuilds in seconds.
# The binary sets .accessory itself, so there is no Dock icon, but without a
# bundle identifier there are no notifications, no login item and no app icon.
set -e
cd "$(dirname "$0")/.."

if [ -z "${DEVELOPER_DIR:-}" ]; then
    if [ -d /Applications/Xcode-beta.app/Contents/Developer ]; then
        export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
    elif [ -d /Applications/Xcode.app/Contents/Developer ]; then
        export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
    fi
fi

swift build 2>&1 | tail -3
pkill -x QuotaBar 2>/dev/null || true
exec .build/debug/QuotaBar
