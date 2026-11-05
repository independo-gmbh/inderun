#!/usr/bin/env bash
# Times the ONNX Articulino runtime on a connected iPhone through the demo app, when a phone is at hand.
#
#   tools/neural-speech/ios_device_bench.sh --device <udid|name> --package <package-dir> [--rounds 5] [--out <file>]
#
# Applies ios-device-bench.patch (a launch-argument hook in IndeRunDemoApp.swift) to the working tree, builds the demo
# app in Release, installs it over the demo on the phone, copies the package into its Documents, runs the benchmark and
# copies Documents/bench.txt back. The patch is reverted on exit; nothing of it is committed or stays in the build that
# a later Xcode run installs. Swift package tests cannot run on a physical device, which is why the demo app is the host.
# Needs Xcode, a paired, unlocked phone with Developer Mode on, and a signing team for the demo project.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../.." && pwd)"
app_file="ios/SampleApps/IndeRunDemo/IndeRunDemo/IndeRunDemoApp.swift"
bundle_id="app.independo.inderun.demo"
device="" package="" rounds=5 out=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --device) device="$2"; shift 2 ;;
    --package) package="$2"; shift 2 ;;
    --rounds) rounds="$2"; shift 2 ;;
    --out) out="$2"; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
[[ -n "$device" && -d "$package" ]] || { echo "usage: $0 --device <udid|name> --package <dir> [--rounds N] [--out <file>]" >&2; exit 2; }
package="$(cd "$package" && pwd)"
name="$(basename "$package")"
out="${out:-$PWD/bench-$(date +%Y%m%d-%H%M%S).txt}"

cd "$root"
git diff --quiet -- "$app_file" || { echo "$app_file has local changes; commit or stash them first" >&2; exit 1; }
work="$(mktemp -d)"
cleanup() { git apply -R "$here/ios-device-bench.patch" 2>/dev/null || true; rm -rf "$work"; }
trap cleanup EXIT
git apply "$here/ios-device-bench.patch"

echo "building the demo app (Release) for $device"
xcodebuild build -project ios/SampleApps/IndeRunDemo/IndeRunDemo.xcodeproj -scheme IndeRunDemo -configuration Release \
  -destination "id=$device" -derivedDataPath "$work/DerivedData" -allowProvisioningUpdates > "$work/build.log" 2>&1 \
  || { tail -20 "$work/build.log" >&2; exit 1; }
git apply -R "$here/ios-device-bench.patch"

xcrun devicectl device install app --device "$device" "$work/DerivedData/Build/Products/Release-iphoneos/IndeRunDemo.app" > /dev/null
xcrun devicectl device copy to --device "$device" --domain-type appDataContainer --domain-identifier "$bundle_id" \
  --source "$package" --destination "Documents/$name" > /dev/null
xcrun devicectl device process launch --device "$device" --terminate-existing "$bundle_id" -- \
  -inderunDeviceBench -inderunBenchRounds "$rounds" -inderunBenchPackage "$name" > /dev/null

echo "running $rounds rounds; keep the phone unlocked"
for _ in $(seq 1 120); do
  sleep 5
  rm -f "$work/bench.txt"
  xcrun devicectl device copy from --device "$device" --domain-type appDataContainer --domain-identifier "$bundle_id" \
    --source Documents/bench.txt --destination "$work/bench.txt" > /dev/null 2>&1 || continue
  if grep -q '^end\|^error' "$work/bench.txt"; then
    cp "$work/bench.txt" "$out"
    cat "$out"
    echo
    echo "written to $out; reinstall the demo from Xcode to drop the hook, delete Documents/$name to free the space"
    exit 0
  fi
done
echo "no result after 10 minutes" >&2
exit 1
