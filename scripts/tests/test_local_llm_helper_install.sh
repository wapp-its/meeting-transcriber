#!/usr/bin/env bash
# Regression test for how the local model helper's resource bundles get into
# the app bundle (scripts/lib/local-llm-helper.sh, sign_local_llm_helper in
# scripts/lib/signing.sh).
#
# The helper's dependencies reach their resources through SwiftPM's
# Bundle.module, which stops the process when the bundle is not beside the
# executable. Copying only the shader bundle by name shipped a helper that died
# on any model folder without a `tokenizer_class`, because
# swift-transformers_Hub.bundle was left behind. So every bundle the build put
# beside the helper is installed, signed and verified, and every bundle an
# earlier run left in Contents/Helpers is cleared first.
#
# Every case runs the real functions against a fake build directory and a
# fake app bundle; `codesign` is a stand-in on PATH that logs its calls.
#
# shellcheck disable=SC2329  # every test function is dispatched by name via run_test

set -uo pipefail   # NOT -e: harness keeps running on test failure

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
STUBS="$(mktemp -d)"
trap 'rm -rf "$STUBS"' EXIT
BUNDLES="mlx-swift_Cmlx.bundle swift-crypto_Crypto.bundle swift-transformers_Hub.bundle"

FAILED=0

run_test() {
    local name="$1"
    printf '%s ... ' "$name"
    if "$2"; then
        printf 'PASS\n'
    else
        printf 'FAIL\n'
        FAILED=1
    fi
}

# Logs every call to $CODESIGN_CALLS. `--verify` fails for a path ending in
# $STUB_BAD_SIGNATURE when that is set; `-d` describes a runtime signature.
cat > "$STUBS/codesign" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${CODESIGN_CALLS:?}"
case "$*" in
    *--verify*)
        if [ -n "${STUB_BAD_SIGNATURE:-}" ]; then
            case "$*" in *"/$STUB_BAD_SIGNATURE") exit 1 ;; esac
        fi ;;
    -d*)
        printf 'CodeDirectory v=20500 size=1 flags=0x10000(runtime) hashes=1+1\n' >&2
        printf 'Authority=Stand-in\n' >&2 ;;
esac
exit 0
STUB
chmod +x "$STUBS/codesign"

# _build_dir <dir>: what the release build leaves, as far as installing cares:
# the helper, its three resource bundles, and build debris that is not a bundle.
_build_dir() {
    local dir="$1" name
    mkdir -p "$dir/LocalLLMHelper.build" || return 1
    printf 'new helper\n' > "$dir/local-llm-helper"
    chmod +x "$dir/local-llm-helper"
    for name in $BUNDLES; do
        mkdir -p "$dir/$name/Contents/Resources" || return 1
        printf 'new %s\n' "$name" > "$dir/$name/Contents/Resources/payload"
    done
}

# _app_with_helper <app>: an app bundle whose Contents/Helpers holds the three
# bundles and the helper, as after an install.
_app_with_helper() {
    local helpers="$1/Contents/Helpers" name
    mkdir -p "$helpers" || return 1
    printf 'helper\n' > "$helpers/local-llm-helper"
    for name in $BUNDLES; do
        mkdir -p "$helpers/$name" || return 1
    done
}

# _in_lib <command...>: runs the command with the helper library sourced and
# the licence install stubbed out (it has its own coverage in the real builds).
_in_lib() {
    (
        # shellcheck source=../lib/local-llm-helper.sh
        source "$REPO_ROOT/scripts/lib/local-llm-helper.sh"
        # shellcheck source=../lib/signing.sh
        source "$REPO_ROOT/scripts/lib/signing.sh"
        install_local_llm_helper_licenses() { return 0; }
        "$@"
    )
}

test_install_copies_every_bundle_and_clears_stale_ones() {
    local work helpers name rc=0
    work="$(mktemp -d)"
    helpers="$work/App.app/Contents/Helpers"
    _build_dir "$work/build" || { echo "  fixture failed" >&2; rm -rf "$work"; return 1; }

    # What an earlier run left: an older helper, a shader bundle with a file
    # the new build no longer has, and a bundle of a dependency since dropped.
    mkdir -p "$helpers/mlx-swift_Cmlx.bundle" "$helpers/gone_Dropped.bundle"
    printf 'old helper\n' > "$helpers/local-llm-helper"
    printf 'old shaders\n' > "$helpers/mlx-swift_Cmlx.bundle/stale.metallib"

    LOCAL_LLM_HELPER_BIN_DIR="$work/build" _in_lib install_local_llm_helper "$work/App.app" > "$work/out.log" 2>&1 \
        || { echo "  install failed:" >&2; sed 's/^/    /' "$work/out.log" >&2; rc=1; }

    for name in $BUNDLES; do
        grep -qx "new $name" "$helpers/$name/Contents/Resources/payload" 2>/dev/null \
            || { echo "  $name was not installed" >&2; rc=1; }
    done
    grep -qx 'new helper' "$helpers/local-llm-helper" || { echo "  the helper was not replaced" >&2; rc=1; }
    [ ! -e "$helpers/mlx-swift_Cmlx.bundle/stale.metallib" ] || { echo "  a stale file survived in the shader bundle" >&2; rc=1; }
    [ ! -e "$helpers/gone_Dropped.bundle" ] || { echo "  a bundle the build no longer produces survived" >&2; rc=1; }
    [ ! -e "$helpers/LocalLLMHelper.build" ] || { echo "  build debris was copied" >&2; rc=1; }
    rm -rf "$work"
    return "$rc"
}

test_sign_signs_every_bundle_before_the_helper() {
    local work calls name rc=0
    work="$(mktemp -d)"
    calls="$work/codesign.log"
    _app_with_helper "$work/App.app" || { echo "  fixture failed" >&2; rm -rf "$work"; return 1; }

    PATH="$STUBS:$PATH" CODESIGN_CALLS="$calls" \
        _in_lib sign_local_llm_helper "$work/App.app" Stand-in --timestamp \
        || { echo "  sign_local_llm_helper failed" >&2; rc=1; }

    for name in $BUNDLES; do
        grep -qx -- "--force --sign Stand-in --timestamp $work/App.app/Contents/Helpers/$name" "$calls" \
            || { echo "  $name was not signed with the extra flags" >&2; rc=1; }
    done
    [ "$(tail -n 1 "$calls")" = "--force --sign Stand-in --options runtime --timestamp $work/App.app/Contents/Helpers/local-llm-helper" ] \
        || { echo "  the helper was not signed last, with the Hardened Runtime:" >&2; sed 's/^/    /' "$calls" >&2; rc=1; }
    [ "$(wc -l < "$calls")" -eq 4 ] || { echo "  expected 4 signatures:" >&2; sed 's/^/    /' "$calls" >&2; rc=1; }
    rm -rf "$work"
    return "$rc"
}

test_verify_checks_every_bundle() {
    local work calls name rc=0
    work="$(mktemp -d)"
    calls="$work/codesign.log"
    _app_with_helper "$work/App.app" || { echo "  fixture failed" >&2; rm -rf "$work"; return 1; }

    PATH="$STUBS:$PATH" CODESIGN_CALLS="$calls" \
        _in_lib verify_local_llm_helper "$work/App.app" > "$work/out.log" 2>&1 \
        || { echo "  verify failed on good signatures:" >&2; sed 's/^/    /' "$work/out.log" >&2; rc=1; }
    for name in $BUNDLES local-llm-helper; do
        grep -qx -- "--verify --strict $work/App.app/Contents/Helpers/$name" "$calls" \
            || { echo "  $name was not verified" >&2; rc=1; }
    done

    # A bundle other than the shader bundle with a broken signature fails it.
    PATH="$STUBS:$PATH" CODESIGN_CALLS="$calls" STUB_BAD_SIGNATURE=swift-transformers_Hub.bundle \
        _in_lib verify_local_llm_helper "$work/App.app" > "$work/out.log" 2>&1 \
        && { echo "  verify passed with a broken signature on swift-transformers_Hub.bundle" >&2; rc=1; }
    rm -rf "$work"
    return "$rc"
}

echo "Testing how the local model helper's resource bundles are installed"
echo
run_test "install copies every bundle and clears stale ones" test_install_copies_every_bundle_and_clears_stale_ones
run_test "sign signs every bundle before the helper" test_sign_signs_every_bundle_before_the_helper
run_test "verify checks every bundle" test_verify_checks_every_bundle

echo
if [ "$FAILED" -eq 0 ]; then
    echo "All tests passed."
else
    echo "Some tests FAILED."
fi
exit "$FAILED"
