#!/bin/zsh
# Unit tests. Works with only the Command Line Tools (no Xcode license needed).
set -e
cd "${0:A:h}/.."
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Library/Developer/CommandLineTools}
F=$DEVELOPER_DIR/Library/Developer/Frameworks
swift test "$@" -Xswiftc -F -Xswiftc $F -Xswiftc -Xfrontend -Xswiftc -disable-cross-import-overlays \
  -Xlinker -F -Xlinker $F -Xlinker -rpath -Xlinker $F 2>&1 | grep -vE "^\[[0-9]+/|Compiling|Write|Emitting| started\.$"
