#!/bin/zsh
# usage: docs/review/inbox-forward/forward-probe.sh <rounds> <commands-per-round> <yes-processes>
set -u
rounds=$1; count=$2; load=$3
root=${0:A:h:h:h:h}
work=$(mktemp -d)
probe=$work/forward-probe
# Top-level code must live in main.swift when compiling several files.
cp ${0:A:h}/forward-probe.swift $work/main.swift
DEVELOPER_DIR=${DEVELOPER_DIR:-/Library/Developer/CommandLineTools} swiftc -O -swift-version 6 \
    -default-isolation MainActor -o $probe \
    $root/Sources/Slightshot/App/ApplicationCommandInbox.swift \
    $root/Sources/Slightshot/App/LaunchCommand.swift \
    $root/Sources/Slightshot/Support/Log.swift \
    $work/main.swift || exit 1
pids=()
for _ in $(seq 1 $load); do yes > /dev/null & pids+=$!; done
trap 'kill $pids 2>/dev/null; rm -rf $work' EXIT
ok=0
for round in $(seq 1 $rounds); do
    inbox=$work/inbox-$round
    $probe owner $inbox $count > $work/owner-$round.log 2>&1 &
    owner=$!
    until grep -q READY $work/owner-$round.log 2>/dev/null || ! kill -0 $owner 2>/dev/null; do sleep 0.05; done
    $probe sender $inbox $count > $work/sender-$round.log 2>&1
    wait $owner && ok=$((ok + 1))
    echo "round=$round $(grep -v READY $work/owner-$round.log) $(cat $work/sender-$round.log)"
done
echo "TOTAL ok=$ok rounds=$rounds commands=$count load=$load"
