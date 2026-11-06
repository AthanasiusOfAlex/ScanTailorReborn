#!/bin/bash
# Test runner. Release builds run the image loops about 80x faster than debug builds.
#   scripts/test.sh fast [filter]    full suite in release (about 1 minute including the build)
#   scripts/test.sh corpus [filter]  the same, plus the real-book tests (needs SCANTAILOR_CORPUS_DIR)
#   scripts/test.sh debug [filter]   full suite in debug (slow, about 10 minutes; keeps the pixel bounds asserts)
# `-Xswiftc -enable-testing` lets release tests use @testable imports.
set -euo pipefail
cd "$(dirname "$0")/.."
sh scripts/sync-skill.sh --check
mode="${1:-fast}"
shift || true
filter=()
if [ "$#" -gt 0 ]; then filter=(--filter "$1"); fi
case "$mode" in
  fast)
    swift test -c release -Xswiftc -enable-testing ${filter[@]+"${filter[@]}"} ;;
  corpus)
    : "${SCANTAILOR_CORPUS_DIR:=$HOME/Library/CloudStorage/OneDrive-MRC/PDFs-in-the-making}"
    export SCANTAILOR_CORPUS_DIR
    swift test -c release -Xswiftc -enable-testing ${filter[@]+"${filter[@]}"} ;;
  debug)
    swift test ${filter[@]+"${filter[@]}"} ;;
  *)
    echo "usage: $0 fast|corpus|debug [filter]" >&2; exit 2 ;;
esac
