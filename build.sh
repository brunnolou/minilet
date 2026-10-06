#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
INSTALL=false
TEST_ONLY=false
case "${1:-}" in
    "") ;;
    --install) INSTALL=true ;;
    --test) TEST_ONLY=true ;;
    *) echo "Usage: ./build.sh [--install | --test]" >&2; exit 1 ;;
esac
if [[ $# -gt 1 ]]; then
    echo "Usage: ./build.sh [--install | --test]" >&2
    exit 1
fi
if [[ "$(uname -s)" != Darwin ]]; then
    echo "Minilet requires macOS." >&2
    exit 1
fi
APP="$HOME/Applications/Minilet.app"
STAGED_APP="$PWD/.build/Minilet.app"
if $INSTALL && pgrep -x Minilet >/dev/null; then
    echo "Quit Minilet before installing so it can restore automatic fan control." >&2
    exit 1
fi
mkdir -p .build
# Combine sources into a Swift entry point without external files or packages.
python3 - <<'PY'
from pathlib import Path
shared = ['Sources/Hardware.swift', 'Sources/Control.swift', 'Sources/Worker.swift']
entries = [('main.swift', ['Sources/Welcome.swift', 'Sources/App.swift']),
           ('test-main.swift', ['Tests/ControllerTests.swift'])]
for name, files in entries:
    Path('.build', name).write_text('\n'.join(Path(f).read_text() for f in shared + files))
PY
TARGET="$(uname -m)-apple-macosx13.0"
swiftc -swift-version 5 -target "$TARGET" .build/test-main.swift -framework IOKit -o .build/control-tests
.build/control-tests
swiftc -swift-version 5 -target "$TARGET" -O .build/main.swift -framework AppKit -framework IOKit -o .build/Minilet
.build/Minilet --menu-self-test
if $TEST_ONLY; then exit 0; fi

# Standard and Retina app icons generated from the retained source image.
ICONSET="$PWD/.build/Minilet.iconset"
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
    sips -z "$size" "$size" Resources/Minilet.png --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    retina=$((size * 2))
    sips -z "$retina" "$retina" Resources/Minilet.png --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
# Only replace our generated staging bundle, never an installed/running app.
rm -rf "$STAGED_APP"
mkdir -p "$STAGED_APP/Contents/MacOS" "$STAGED_APP/Contents/Resources"
cp .build/Minilet "$STAGED_APP/Contents/MacOS/Minilet"
cp Info.plist "$STAGED_APP/Contents/Info.plist"
cp LICENSE.md "$STAGED_APP/Contents/Resources/LICENSE.md"
iconutil -c icns "$ICONSET" -o "$STAGED_APP/Contents/Resources/Minilet.icns"
plutil -lint "$STAGED_APP/Contents/Info.plist"
codesign --force --sign - "$STAGED_APP"
codesign --verify --deep --strict "$STAGED_APP"
ditto -c -k --sequesterRsrc --keepParent "$STAGED_APP" .build/Minilet.zip
echo "Built $STAGED_APP"
echo "Archive: $PWD/.build/Minilet.zip"
if $INSTALL; then
    mkdir -p "$HOME/Applications"
    ditto "$STAGED_APP" "$APP"
    touch "$APP"
    echo "Installed $APP"
    echo "Launch with: open '$APP'"
fi
