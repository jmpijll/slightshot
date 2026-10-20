#!/bin/zsh
# usage: docs/review/inbox-forward/loaded-repeat.sh <runs> <parallel> <yes-processes>
# Runs ApplicationCommandInboxTests from the already built test bundle <runs> times while
# <yes-processes> copies of `yes` load the CPU. Build first with `swift build --build-tests`.
# Export INBOX58_STALL_SECONDS with stall-probe-*.patch applied to block the main actor.
set -u
root=${0:A:h:h:h:h}
bundle=$root/.build/arm64-apple-macosx/debug/SlightshotPackageTests.xctest/Contents/MacOS/SlightshotPackageTests
export DEVELOPER_DIR=/Library/Developer/CommandLineTools
export DYLD_LIBRARY_PATH=$DEVELOPER_DIR/Library/Developer/usr/lib
if [[ $1 == --one ]]; then
    log=$($DEVELOPER_DIR/usr/libexec/swift/pm/swiftpm-testing-helper --test-bundle-path $bundle $bundle \
        --testing-library swift-testing --filter ApplicationCommandInboxTests 2>&1)
    if print -r -- "$log" | grep -q "Test run with .* passed"; then echo "run=$2 PASS"
    else echo "run=$2 FAIL $(print -r -- "$log" | grep -m1 "✘" | cut -c1-160)"; fi
    exit
fi
runs=$1; par=$2; load=$3
pids=()
for _ in $(seq 1 $load); do yes > /dev/null & pids+=$!; done
trap 'kill $pids 2>/dev/null' EXIT
results=$(seq 1 $runs | xargs -P $par -I{} $0 --one {})
print -r -- "$results"
echo "TOTAL pass=$(grep -c PASS <<< $results) fail=$(grep -c FAIL <<< $results) runs=$runs" \
    "parallel=$par load=$load stall=${INBOX58_STALL_SECONDS:-0} loadavg=$(sysctl -n vm.loadavg)"
