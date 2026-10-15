#!/usr/bin/env bash
# Pre-push parity check. Runs the strictest local builds that surface issues
# CI's release pipeline would otherwise catch first.
#
# Usage:
#   ./scripts/pre-push.sh                     # release build of the app and its helper
#   ./scripts/pre-push.sh --with-tests        # also build the test target
#   ./scripts/pre-push.sh --with-appstore     # also build the App Store variant
#   ./scripts/pre-push.sh --all               # everything
#
# Why this exists: `swift build` (debug) and `swift build -c release` use
# different Sendable-inference rules. Release mode enables WMO which can
# surface concurrency diagnostics that incremental debug builds tolerate
# (see PR #191 for the canonical example: ScreenCaptureKit Sendable hop
# only failed under -c release on CI). Running release locally before
# `git push` keeps that round-trip out of CI.

set -euo pipefail
cd "$(dirname "$0")/.."

WITH_TESTS=0
WITH_APPSTORE=0

for arg in "$@"; do
    case "$arg" in
        --with-tests) WITH_TESTS=1 ;;
        --with-appstore) WITH_APPSTORE=1 ;;
        --all) WITH_TESTS=1; WITH_APPSTORE=1 ;;
        -h|--help)
            sed -n '2,11p' "$0"
            exit 0
            ;;
        *)
            echo "unknown flag: $arg" >&2
            exit 2
            ;;
    esac
done

# Sourced before the cd below, while this relative path still resolves.
# shellcheck source=lib/local-llm-helper.sh
source scripts/lib/local-llm-helper.sh

cd app/MeetingTranscriber

echo "==> swift build -c release (Homebrew variant)"
swift build -c release

# The Homebrew bundle carries the local model helper, its own package, which
# needs Xcode's Metal Toolchain. A machine without it can still push app-only
# changes, so the helper is skipped there with one line rather than failing.
if metal_toolchain_installed; then
    echo "==> swift build -c release (local model helper)"
    build_local_llm_helper
else
    echo "==> skipped the local model helper: Xcode's Metal Toolchain is not installed (xcodebuild -downloadComponent MetalToolchain)"
fi

if [[ "$WITH_APPSTORE" == 1 ]]; then
    echo "==> swift build -c release -DAPPSTORE (App Store variant)"
    swift build -c release -Xswiftc -DAPPSTORE
fi

if [[ "$WITH_TESTS" == 1 ]]; then
    echo "==> swift build --target MeetingTranscriberTests"
    swift build --target MeetingTranscriberTests
fi

echo
echo "OK — pre-push parity check passed."
