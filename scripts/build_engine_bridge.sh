#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/../.." && pwd)
OUT_DIR="$ROOT_DIR/iOS/Vendor"
OUT="$OUT_DIR/EngineBridge.xcframework"

GOMOBILE=$(command -v gomobile || true)
if [ -z "$GOMOBILE" ]; then
  GOPATH=$(go env GOPATH)
  if [ -x "$GOPATH/bin/gomobile" ]; then
    GOMOBILE="$GOPATH/bin/gomobile"
  fi
fi

if [ -z "$GOMOBILE" ]; then
  echo "gomobile is not installed. Install it with:"
  echo "  go install golang.org/x/mobile/cmd/gomobile@latest"
  echo "  gomobile init"
  exit 1
fi
PATH="$(dirname "$GOMOBILE"):$PATH"
export PATH

mkdir -p "$OUT_DIR"
cd "$ROOT_DIR/MasterDnsVPN"
"$GOMOBILE" bind -target ios -o "$OUT" ./mobilebridge
echo "Wrote $OUT"
