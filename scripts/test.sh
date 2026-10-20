#!/bin/zsh
# Runs the unit tests. With full Xcode this is just `swift test`; with only the Command Line Tools,
# SwiftPM doesn't find the bundled Swift Testing framework on its own, so point it there.
set -euo pipefail
cd "$(dirname "$0")/.."

DEV="$(xcode-select -p 2>/dev/null || true)"
if [[ "$DEV" == *CommandLineTools* ]]; then
  F="$DEV/Library/Developer/Frameworks"
  L="$DEV/Library/Developer/usr/lib"
  exec swift test -Xswiftc -F -Xswiftc "$F" -Xlinker -F -Xlinker "$F" \
    -Xlinker -rpath -Xlinker "$F" -Xlinker -rpath -Xlinker "$L" "$@"
fi
exec swift test "$@"
