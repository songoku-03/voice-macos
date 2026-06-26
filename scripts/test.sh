#!/bin/bash
# Run the Swift Testing suite.
#
# The Command Line Tools ship the Swift Testing framework but SwiftPM doesn't add
# its search/runtime paths automatically, so we pass them explicitly. With a full
# Xcode install these flags are unnecessary (`swift test` finds Testing on its own),
# but they're harmless. See AGENTS.md / the ECC swift-protocol-di-testing skill.
set -e

DEV="$(xcode-select -p)"
# CommandLineTools layout: frameworks + the _TestingInterop runtime live in separate dirs.
FW="$DEV/Library/Developer/Frameworks"
LIB="$DEV/Library/Developer/usr/lib"

if [ -d "$FW/Testing.framework" ]; then
  exec swift test \
    -Xswiftc -F -Xswiftc "$FW" \
    -Xlinker -rpath -Xlinker "$FW" \
    -Xlinker -rpath -Xlinker "$LIB" \
    "$@"
else
  # Full Xcode toolchain — Testing is on the default search path.
  exec swift test "$@"
fi
