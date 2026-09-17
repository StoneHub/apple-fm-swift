#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
test -z "$(git status --porcelain)" || { echo 'Commit changes before packaging.' >&2; exit 1; }
version=$(cat VERSION)
mkdir -p release
git archive --format=tar.gz --prefix="apple-fm-swift-$version/" -o "release/apple-fm-swift-$version-source.tar.gz" HEAD
(cd release && shasum -a 256 "apple-fm-swift-$version-source.tar.gz" > SHA256SUMS)
echo "Packaged source $version from $(git rev-parse HEAD)"
