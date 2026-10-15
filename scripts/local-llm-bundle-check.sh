#!/usr/bin/env bash
# Verify the local model helper works from inside a signed app bundle, not only
# from its SwiftPM build directory. MLX finds its compiled Metal shaders through
# the helper's main bundle (see scripts/lib/local-llm-helper.sh), so the
# placement inside the .app is the case that needs proving, together with the
# signatures and the Hardened Runtime the helper is signed with. This script is
# that check, in the manner of scripts/localvqe-bundle-check.sh.
#
# Usage:
#   ./scripts/local-llm-bundle-check.sh [<app-bundle>]
#
#   <app-bundle>   Defaults to the dev bundle `run_app.sh --build-only` builds,
#                  the one mt-update installs. For build_release.sh's bundle
#                  pass .build/release/MeetingTranscriber.app.
#
# It builds nothing; run the build script first. It needs a GPU, because the
# helper's selftest runs real Metal kernels.
#
# Output: one line per check, the selftest's own lines, then
# `local-llm-bundle-check: OK` and exit 0. The first check that fails prints
# `FAIL: <what>` on stderr and exits 1.
#
# The selftest runs from an empty working directory. MLX looks for its shaders
# next to the binary, then in the main bundle's shader bundle, and last in
# `default.metallib` in the working directory; with that last place empty, a
# pass can only come from the shaders inside the app bundle. A helper with no
# shader bundle does not fail cleanly, it traps (measured), so this check tests
# the bundle's presence directly instead of provoking that crash, which would
# leave a crash report of the helper behind on every run.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=lib/local-llm-helper.sh
source "$SCRIPT_DIR/lib/local-llm-helper.sh"

fail() {
    echo "FAIL: $1" >&2
    exit 1
}

case "$#" in
    0) APP_BUNDLE="$PROJECT_ROOT/app/MeetingTranscriber/.build/MeetingTranscriber-Dev.app" ;;
    1) APP_BUNDLE="$1" ;;
    *) echo "usage: $(basename "$0") [<app-bundle>]" >&2; exit 2 ;;
esac
[ -d "$APP_BUNDLE" ] || fail "no app bundle at $APP_BUNDLE (build it first)"
# Absolute, because the selftest below runs from another working directory.
APP_BUNDLE="$(cd "$APP_BUNDLE" && pwd)"
HELPER_DIR="$APP_BUNDLE/$LOCAL_LLM_HELPER_DIR"
HELPER="$HELPER_DIR/$LOCAL_LLM_HELPER_NAME"
SHADERS="$HELPER_DIR/$LOCAL_LLM_SHADER_BUNDLE/Contents/Resources/default.metallib"

echo "=== local-llm-bundle-check: $APP_BUNDLE ==="

[ -x "$HELPER" ] || fail "no helper executable at $HELPER"
[ -f "$SHADERS" ] || fail "no shader bundle: $SHADERS is missing"
echo "Helper and shader bundle present in $LOCAL_LLM_HELPER_DIR"

verify_local_llm_helper "$APP_BUNDLE" || fail "the helper's signature does not verify"
codesign --verify --deep --strict "$APP_BUNDLE" || fail "the app bundle's signature does not verify"
echo "App bundle signature verified"

EMPTY_CWD="$(mktemp -d)"
trap 'rmdir "$EMPTY_CWD"' EXIT

echo ""
echo "--- selftest of the bundled helper ---"
if ! OUT="$(cd "$EMPTY_CWD" && "$HELPER" selftest 2>&1)"; then
    echo "$OUT"
    fail "the bundled helper's selftest exited non-zero"
fi
echo "$OUT"
grep -qx "SELFTEST OK" <<< "$OUT" || fail "the bundled helper's selftest did not report SELFTEST OK"

echo ""
echo "local-llm-bundle-check: OK"
