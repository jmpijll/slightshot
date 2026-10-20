#!/bin/bash
# Records the make lint and VERSION checks for this review: run from the repo root.
set -u
probe=Sources/Slightshot/App/StatusItemController.swift
run() { printf '$ %s\n' "$*"; "$@" 2>&1 | sed "s|$(pwd -P)/||; s|$PWD/||"; printf '[exit %s]\n\n' "${PIPESTATUS[0]}"; }

echo "# source $(git rev-parse --short HEAD)"
echo
run make lint
printf '$ # temporary force cast appended to %s\n' "$probe"
printf 'private let lintProbe = NSObject() as! NSString\n' >> "$probe"
run make lint
git checkout -q -- "$probe"
printf '$ # SwiftLint absent from PATH\n'
PATH=/usr/bin:/bin run make lint

clone=$(mktemp -d)/clone
git clone -q --no-tags "$PWD" "$clone"
printf '$ # tagless clone: %s tags\n' "$(git -C "$clone" tag | wc -l | tr -d ' ')"
(cd "$clone" && run make -n release)
rm -rf "$(dirname "$clone")"
run actionlint
run shellcheck Scripts/bundle.sh Scripts/make_dmg.sh Scripts/notarize.sh
