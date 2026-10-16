#!/usr/bin/env bash
# Verify the local model helper works from inside a signed app bundle, not only
# from its SwiftPM build directory. MLX and the helper's other dependencies find
# their resource bundles through the helper's main bundle (see
# scripts/lib/local-llm-helper.sh), so the placement inside the .app is the case
# that needs proving, together with the signatures and the Hardened Runtime the
# helper is signed with. This script is that check, in the manner of
# scripts/localvqe-bundle-check.sh.
#
# Usage:
#   ./scripts/local-llm-bundle-check.sh [<app-bundle>]
#
#   <app-bundle>   Defaults to the dev bundle `run_app.sh --build-only` builds,
#                  the one mt-update installs. For build_release.sh's bundle
#                  pass .build/release/MeetingTranscriber.app.
#
# It builds nothing; run the build script first. It compares the app bundle
# with the helper's build output in this checkout, so the bundle has to come
# from this checkout's build. It needs a GPU, because the helper's selftest runs
# real Metal kernels.
#
# Output: one line per check, the selftest's own lines, then
# `local-llm-bundle-check: OK` and exit 0. The first check that fails prints
# `FAIL: <what>` on stderr and exits 1.
#
# The checks:
#   - every resource bundle the build put beside the helper is in the app too,
#     because a missing one stops the helper only once something reaches for it;
#   - the nested signatures and the app's verify;
#   - the selftest, run from an empty working directory: MLX looks for its
#     shaders next to the binary, then in the main bundle's shader bundle, and
#     last in `default.metallib` in the working directory, so with that last
#     place empty a pass can only come from the shaders inside the app;
#   - `check` on a generated model folder whose tokenizer_config.json has no
#     `tokenizer_class`, which makes swift-transformers load its fallback
#     configuration from its own resource bundle. That proves SwiftPM's
#     Bundle.module finds a dependency's bundle inside the app. The folder has
#     no weights, so nothing is loaded.
#
# No check provokes a failure on purpose: a helper missing a bundle does not
# fail cleanly, it traps (measured), and would leave a crash report on every
# run. The bundles' presence is checked directly instead.

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
# Absolute, because the helper runs below from another working directory.
APP_BUNDLE="$(cd "$APP_BUNDLE" && pwd)"
HELPER_DIR="$APP_BUNDLE/$LOCAL_LLM_HELPER_DIR"
HELPER="$HELPER_DIR/$LOCAL_LLM_HELPER_NAME"
SHADERS="$HELPER_DIR/$LOCAL_LLM_SHADER_BUNDLE/Contents/Resources/default.metallib"

echo "=== local-llm-bundle-check: $APP_BUNDLE ==="

BUILD_DIR="$(local_llm_helper_bin_dir)" || fail "SwiftPM did not name the helper's build directory"
[ -x "$BUILD_DIR/$LOCAL_LLM_HELPER_NAME" ] \
    || fail "no helper build in $BUILD_DIR to compare the app bundle with (run the build script first)"

[ -x "$HELPER" ] || fail "no helper executable at $HELPER"
BUNDLES=""
for built in "$BUILD_DIR"/*.bundle; do
    [ -d "$built" ] || continue
    name="${built##*/}"
    [ -d "$HELPER_DIR/$name" ] || fail "the build produced $name, which $HELPER_DIR lacks"
    BUNDLES="$BUNDLES $name"
done
[ -f "$SHADERS" ] || fail "no shader bundle: $SHADERS is missing"
echo "Helper and the build's resource bundles present in $LOCAL_LLM_HELPER_DIR:$BUNDLES"

verify_local_llm_helper "$APP_BUNDLE" || fail "the helper's signature does not verify"
codesign --verify --deep --strict "$APP_BUNDLE" || fail "the app bundle's signature does not verify"
echo "App bundle signature verified"

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK:?}"' EXIT
EMPTY_CWD="$WORK/cwd"
MODEL="$WORK/model-without-tokenizer-class"
mkdir "$EMPTY_CWD" "$MODEL"

echo ""
echo "--- selftest of the bundled helper ---"
if ! OUT="$(cd "$EMPTY_CWD" && "$HELPER" selftest 2>&1)"; then
    echo "$OUT"
    fail "the bundled helper's selftest exited non-zero"
fi
echo "$OUT"
grep -qx "SELFTEST OK" <<< "$OUT" || fail "the bundled helper's selftest did not report SELFTEST OK"

echo ""
echo "--- a dependency's resource bundle, through Bundle.module ---"
# gpt2 is one of the model types swift-transformers ships a fallback
# configuration for. The folder is unusable (no weights, no chat template, a
# model type MLX does not run), so `check` exits non-zero by design; what
# matters is that it answers at all and that the tokenizer loaded.
printf '{"model_type": "gpt2"}\n' > "$MODEL/config.json"
printf '{}\n' > "$MODEL/tokenizer_config.json"
printf '%s\n' '{"version": "1.0", "added_tokens": [], "normalizer": null, "pre_tokenizer": null,' \
    '"post_processor": null, "decoder": null,' \
    '"model": {"type": "BPE", "vocab": {"a": 0, "b": 1, "ab": 2}, "merges": ["a b"]}}' \
    > "$MODEL/tokenizer.json"
STATUS=0
OUT="$(cd "$EMPTY_CWD" && "$HELPER" check "$MODEL" 2>&1)" || STATUS=$?
echo "$OUT"
[ "$STATUS" -lt 128 ] || fail "the bundled helper died (status $STATUS) checking a model folder without a tokenizer_class"
grep -q '"modelType":"gpt2"' <<< "$OUT" || fail "the bundled helper's check printed no report"
if grep -q '"file":"tokenizer.json"' <<< "$OUT"; then
    fail "the bundled helper could not load a tokenizer through swift-transformers' fallback configuration"
fi
echo "Tokenizer loaded: swift-transformers found its resource bundle inside the app"

echo ""
echo "local-llm-bundle-check: OK"
