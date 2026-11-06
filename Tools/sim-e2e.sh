#!/bin/zsh
# End to end on the iOS simulator against the Mac helper in dry-run mode: the phone app really pairs,
# connects and sends; the helper records every command to a file instead of acting on this Mac.
# Safe to run any time — no cursor, keys, windows or permission prompts on the Mac.
#   Tools/sim-e2e.sh                       the helper-path tests
#   Tools/sim-e2e.sh test3_TypeIntoMac     one test
set -e
cd "${0:A:h}/.."
SIM=${FLICK_SIM:-$(xcrun simctl list devices available | grep -m1 -E "iPhone 1[5-7] Pro" | sed -E 's/.*\(([0-9A-F-]{36})\).*/\1/')}
CODE=246810
T=${TMPDIR:-/tmp}/flick-sim-e2e
rm -rf $T && mkdir -p $T

export DEVELOPER_DIR=/Library/Developer/CommandLineTools
swift build --product FlickMac -q
unset DEVELOPER_DIR
FLICK_LOG=1 FLICK_DRY_RUN=$T/commands.log FLICK_DATA_DIR=$T/data FLICK_PAIR_CODE=$CODE FLICK_NO_PROMPT=1 FLICK_HEADLESS=1 \
  .build/debug/FlickMac > $T/mac.log 2>&1 &
MAC=$!
trap "kill $MAC 2>/dev/null" EXIT
sleep 2
kill -0 $MAC || { echo "helper didn't start:"; cat $T/mac.log; exit 1 }

xcrun simctl boot $SIM 2>/dev/null || true
xcodegen generate -q
# Screen streaming (needs capture permission) and the probe-window screen tap are device-only (Tools/e2e.sh).
DEFAULT=(test0_WrongCodeIsRejected test1_PairAndConnect test2_TrackpadMoves test3_TypeIntoMac test4_AirPointer test6_MoreAndModes
         test7_AskClaude test9_ShortcutConnection testS1_AskWithoutMacOffersPairing)
if (( $# )); then LIST=($@); else LIST=($DEFAULT); fi
ONLY=(); for t in $LIST; do ONLY+=(-only-testing:FlickUITests/FlickUITests/$t); done
set +e
TEST_RUNNER_FLICK_CODE=$CODE xcodebuild test -project Flick.xcodeproj -scheme Flick -destination "id=$SIM" \
  -derivedDataPath build/sim -resultBundlePath $T/results.xcresult $ONLY 2>&1 \
  | grep -E "Test Case .*(passed|failed)|error:" | grep -v "exit code 0"
STATUS=${pipestatus[1]}
set -e

echo "--- what reached the Mac helper"
python3 - $T/commands.log "${LIST[*]}" <<'PY'
import re, sys
lines = open(sys.argv[1]).read().splitlines()
ran = sys.argv[2].split()
moves = [tuple(map(float, m)) for m in (re.findall(r"move\(dx: ([-\d.e]+), dy: ([-\d.e]+)\)", l) for l in lines) for m in m]
typed = "".join(re.findall(r'text\(value: "(.*)"\)', "\n".join(lines)))
checks = {
    "test2_TrackpadMoves": ("trackpad drag moved right", len(moves) > 5 and sum(dx for dx, _ in moves) > 50),
    "test3_TypeIntoMac": ("typed 'hi flick' + return", "hi flick" in typed and any("key(key: FlickKit.Key.return" in l or "return" in l and l.startswith("key(") for l in lines)),
    "test4_AirPointer": ("air pointer aimed", sum(l.startswith(("point(", "move(")) for l in lines) > 2),
    "test7_AskClaude": ("ask reached the Mac", any(l.startswith("ask(") for l in lines)),
    "test9_ShortcutConnection": ("one-shot sent releaseAll", any(l.startswith("releaseAll") for l in lines)),
}
print(f"{len(lines)} commands, {len(moves)} moves (Σdx {sum(dx for dx, _ in moves):.0f}), typed {typed!r}")
bad = 0
for t, (what, ok) in checks.items():
    if t in ran:
        print(("PASS " if ok else "FAIL ") + what); bad += not ok
sys.exit(1 if bad else 0)
PY
MACSIDE=$?
exit $(( STATUS || MACSIDE ))
