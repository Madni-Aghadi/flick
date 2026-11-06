#!/bin/zsh
# End to end on the real iPhone: runs the Mac side in test mode (probe window + fixed pairing code),
# drives the iPhone app with XCUITest, then checks on the Mac what actually happened.
#   Tools/e2e.sh                 all UI tests
#   Tools/e2e.sh test3_TypeIntoMac   one test
set -e
cd "${0:A:h}/.."
UDID=${FLICK_UDID:-$(xcrun xctrace list devices 2>/dev/null | grep -m1 -E "iPhone.*\([0-9A-F-]{25}\)" | sed -E 's/.*\(([0-9A-F-]{25})\)$/\1/')}
CODE=246810
T=${TMPDIR:-/tmp}/flick-e2e
rm -rf $T && mkdir -p $T
DATA=$PWD/build/e2e-data   # kept between runs so single tests reuse the pairing
mkdir -p $DATA

idle() { ioreg -c IOHIDSystem | awk '/HIDIdleTime/ {print int($NF/1000000000); exit}' }
if (( $(idle) < 15 )) && [[ -z $FLICK_FORCE ]]; then
  echo "Mac is in use (idle $(idle)s). These tests move the cursor and type. Re-run when away, or FLICK_FORCE=1."
  exit 2
fi

export DEVELOPER_DIR=/Library/Developer/CommandLineTools
swift build --product FlickMac -q
unset DEVELOPER_DIR
pkill -f "debug/FlickMac" 2>/dev/null || true
pkill -x Flick 2>/dev/null || true
FLICK_DATA_DIR=$DATA FLICK_PAIR_CODE=$CODE FLICK_PROBE=$T/probe.json FLICK_NO_PROMPT=1 .build/debug/FlickMac > $T/mac.log 2>&1 &
MAC=$!
trap "kill $MAC 2>/dev/null; kill \$SAMPLER 2>/dev/null" EXIT
sleep 2

# Where the probe window sits on the Mac, for the screen-tap test.
sleep 1
eval $(python3 -c "
import json, Quartz
f = json.load(open('$T/probe.json'))['frame']; b = Quartz.CGDisplayBounds(Quartz.CGMainDisplayID())
print(f'export TEST_RUNNER_FLICK_PROBE_X={(f[0]+f[2]/2)/b.size.width:.4f} TEST_RUNNER_FLICK_PROBE_Y={(f[1]+f[3]/2)/b.size.height:.4f} TEST_RUNNER_FLICK_MAC_ASPECT={b.size.width/b.size.height:.4f}')
" 2>/dev/null || echo "export TEST_RUNNER_FLICK_PROBE_X=0.24 TEST_RUNNER_FLICK_PROBE_Y=0.687 TEST_RUNNER_FLICK_MAC_ASPECT=1.5447")

# Cursor trace while the phone drives it.
( while true; do python3 -c "import Quartz; p=Quartz.CGEventGetLocation(Quartz.CGEventCreate(None)); print(int(p.x), int(p.y))" 2>/dev/null || osascript -l JavaScript -e 'ObjC.import("CoreGraphics"); var p=$.CGEventGetLocation($.CGEventCreate(null)); p.x.toFixed(0)+" "+p.y.toFixed(0)'; sleep 0.1; done ) > $T/cursor.log &
SAMPLER=$!

ONLY=()
for t in "$@"; do ONLY+=(-only-testing:FlickUITests/FlickUITests/$t); done
xcodegen generate -q
set +e
TEST_RUNNER_FLICK_CODE=$CODE xcodebuild test -project Flick.xcodeproj -scheme Flick -destination "id=$UDID" \
  -allowProvisioningUpdates -derivedDataPath build/dd -resultBundlePath $T/results.xcresult $ONLY 2>&1 \
  | grep -E "Test Case|error:|passed|failed|BUILD" | grep -v "^$"
STATUS=${pipestatus[1]}
set -e
kill $SAMPLER 2>/dev/null

echo "--- Mac side"
python3 - "$T" <<'PY'
import json, sys, os
t = sys.argv[1]
probe = json.load(open(f"{t}/probe.json")) if os.path.exists(f"{t}/probe.json") else {}
pts = [tuple(map(int, l.split())) for l in open(f"{t}/cursor.log") if len(l.split()) == 2]
xs = [p[0] for p in pts]
print(f"cursor samples {len(pts)}, x range {min(xs) if xs else 0}..{max(xs) if xs else 0}")
print(f"probe text {probe.get('text','')!r}")
PY
xcrun xcresulttool export attachments --path $T/results.xcresult --output-path $T/shots >/dev/null 2>&1 || true
ls $T/shots 2>/dev/null | head -20
echo "artifacts in $T"
exit $STATUS
