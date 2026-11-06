#!/bin/zsh
# Bluetooth mode on the real iPhone (no Mac app in the loop): the phone must already be connected
# to this Mac over Bluetooth. Runs only while nobody is using the Mac; checks what arrived.
cd "${0:A:h}/.."
D=${FLICK_UDID:-$(xcrun xctrace list devices 2>/dev/null | grep -m1 -E "iPhone.*\([0-9A-F-]{25}\)" | sed -E 's/.*\(([0-9A-F-]{25})\)$/\1/')}
T=$PWD/build/bt-e2e; rm -rf $T; mkdir -p $T
idle() { ioreg -c IOHIDSystem | awk '/HIDIdleTime/ {print int($NF/1000000000); exit}' }
waitidle() { until (( $(idle) >= ${1:-30} )); do sleep 5; done }
# Small CoreGraphics helpers from Tools/probes, built on first use.
tool() { local b=build/probes/$1; [[ -x $b ]] || { mkdir -p build/probes && swiftc -O Tools/probes/$1.swift -o $b }; $b "${@:2}" }
cur() { tool cursorpos }
MAC=""
trap 'kill $MAC 2>/dev/null' EXIT
# The probe window only exists while a test runs (and only once nobody is using the Mac).
openprobe() {
  waitidle ${1:-30}
  FLICK_DATA_DIR=$T/data FLICK_PROBE=$T/probe.json FLICK_NO_PROMPT=1 .build/debug/FlickMac > $T/mac.log 2>&1 &
  MAC=$!; sleep 2
}
closeprobe() { kill $MAC 2>/dev/null; MAC="" }
run() {
  xcodebuild test-without-building -project Flick.xcodeproj -scheme Flick -destination "id=$D" -derivedDataPath build/dd \
    -resultBundlePath $T/$1.xcresult -only-testing:FlickUITests/FlickUITests/$1 2>&1 | grep -E "Test Case.*(passed|failed)|error:" | head -3
}
focusprobe() { osascript -e "tell application \"System Events\" to set frontmost of (first process whose unix id is $MAC) to true" 2>/dev/null; }
probe() { python3 -c "import json;p=json.load(open('$T/probe.json'));print('$1', p['$1'])"; }

openprobe 120; b=$(cur); run testB1_BluetoothTrackpad; echo "   cursor $b -> $(cur)"; closeprobe
sleep 22; openprobe 120; focusprobe; sleep 1; run testB2_BluetoothTyping; probe text; closeprobe
sleep 22; openprobe 120
f=$(python3 -c "import json;f=json.load(open('$T/probe.json'))['frame'];print(int(f[0]+f[2]/2), int(f[1]+f[3]/2))")
tool warp ${=f}; focusprobe; sleep 1; run testB3_BluetoothClicks; probe clicks; closeprobe
sleep 22; waitidle 120; b=$(cur); run testB4_BluetoothAir; echo "   cursor $b -> $(cur)"
run testB5_BluetoothScreens
echo "artifacts in $T"
