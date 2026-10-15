#!/usr/bin/env bash
# Regression test for the Metal Toolchain gate of the local model helper
# (scripts/lib/local-llm-helper.sh).
#
# The helper links MLX, whose shaders only compile with Xcode's Metal Toolchain
# component installed. Without it SwiftPM fails deep inside the build with a
# message that names no remedy, so both Homebrew builds check first and stop
# with the install command, and pre-push.sh, which must keep working for
# app-only changes on a machine without the component, skips the helper with
# one line instead.
#
# Every case runs a copy of the scripts against stand-ins on PATH: `xcodebuild`
# answers -showComponent as told, `swift` builds nothing and logs where it was
# asked to build. Neither this machine's toolchain nor a real build decides the
# outcome.
#
# shellcheck disable=SC2329  # every test function is dispatched by name via run_test

set -uo pipefail   # NOT -e: harness keeps running on test failure

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
STUBS="$(mktemp -d)"
trap 'rm -rf "$STUBS"' EXIT
INSTALL_COMMAND="xcodebuild -downloadComponent MetalToolchain"

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

# STUB_METAL: `installed`, `uninstalled`, or `error` (xcodebuild failing the
# query, as an Xcode that predates the component does).
cat > "$STUBS/xcodebuild" <<'STUB'
#!/usr/bin/env bash
case "${STUB_METAL:?}" in
    installed|uninstalled) printf 'Build Version: 0\nStatus: %s\n' "$STUB_METAL" ;;
    *) echo "xcodebuild: error: Unknown component type" >&2; exit 70 ;;
esac
STUB
cat > "$STUBS/swift" <<'STUB'
#!/usr/bin/env bash
printf '%s %s\n' "$PWD" "$*" >> "${SWIFT_CALLS:?}"
for arg in "$@"; do
    [ "$arg" = --show-bin-path ] && printf '%s\n' "$PWD/.build/release"
done
exit 0
STUB
chmod +x "$STUBS/xcodebuild" "$STUBS/swift"

# A copy of the scripts and the slice of the repository they touch before and
# around the helper build, in $1/repo.
_stage() {
    local root="$1/repo"
    mkdir -p "$root/scripts/lib" "$root/app/MeetingTranscriber/Sources" \
        "$root/tools/local-llm-helper/.build/release/mlx-swift_Cmlx.bundle" || return 1
    cp "$REPO_ROOT"/scripts/build_release.sh "$REPO_ROOT"/scripts/run_app.sh \
        "$REPO_ROOT"/scripts/pre-push.sh "$root/scripts/" || return 1
    cp "$REPO_ROOT"/scripts/lib/*.sh "$root/scripts/lib/" || return 1
    # lib/bundle-ids.sh reads the bundle identifier from it when sourced.
    cp "$REPO_ROOT/app/MeetingTranscriber/Sources/Info.plist" "$root/app/MeetingTranscriber/Sources/" || return 1
    printf '0.0.0\n' > "$root/VERSION"
    printf 'helper build\n' > "$root/tools/local-llm-helper/.build/release/local-llm-helper"
    chmod +x "$root/tools/local-llm-helper/.build/release/local-llm-helper"
}

# _run <workdir> <metal-answer> <script> [args...]: output to $1/run.log, swift
# calls to $1/swift.log, status returned.
_run() {
    local workdir="$1" metal="$2" script="$3"
    shift 3
    : > "$workdir/swift.log"
    PATH="$STUBS:$PATH" STUB_METAL="$metal" SWIFT_CALLS="$workdir/swift.log" \
        bash "$workdir/repo/scripts/$script" "$@" > "$workdir/run.log" 2>&1
}

test_probe_reads_the_component_status() {
    local metal want rc=0
    for metal in installed:0 uninstalled:1 error:1; do
        want="${metal#*:}"
        metal="${metal%%:*}"
        PATH="$STUBS:$PATH" STUB_METAL="$metal" bash -c \
            'set -euo pipefail; source "$1"; metal_toolchain_installed' bash \
            "$REPO_ROOT/scripts/lib/local-llm-helper.sh"
        if [ "$?" -ne "$want" ]; then
            echo "  xcodebuild answering '$metal': expected status $want" >&2
            rc=1
        fi
    done
    return "$rc"
}

# Both Homebrew builds stop before compiling anything, with the remedy.
_expect_stop_with_install_command() {
    local script="$1" workdir status rc=0
    shift
    workdir="$(mktemp -d)"
    _stage "$workdir" || { echo "  fixture failed" >&2; rm -rf "$workdir"; return 1; }

    _run "$workdir" uninstalled "$script" "$@"
    status=$?

    [ "$status" -ne 0 ] || { echo "  $script exited 0 without the Metal Toolchain" >&2; rc=1; }
    grep -qF "$INSTALL_COMMAND" "$workdir/run.log" \
        || { echo "  $script did not name '$INSTALL_COMMAND'; it printed:" >&2; sed 's/^/    /' "$workdir/run.log" >&2; rc=1; }
    [ ! -s "$workdir/swift.log" ] \
        || { echo "  $script built before it checked:" >&2; sed 's/^/    /' "$workdir/swift.log" >&2; rc=1; }
    rm -rf "$workdir"
    return "$rc"
}

test_build_release_stops_without_the_toolchain() {
    _expect_stop_with_install_command build_release.sh --no-notarize
}

test_run_app_stops_without_the_toolchain() {
    _expect_stop_with_install_command run_app.sh --build-only
}

test_pre_push_skips_the_helper_with_one_line() {
    local workdir status rc=0
    workdir="$(mktemp -d)"
    _stage "$workdir" || { echo "  fixture failed" >&2; rm -rf "$workdir"; return 1; }

    _run "$workdir" uninstalled pre-push.sh
    status=$?
    [ "$status" -eq 0 ] || { echo "  pre-push.sh exited $status without the Metal Toolchain" >&2; rc=1; }
    [ "$(grep -c 'local model helper' "$workdir/run.log")" -eq 1 ] \
        || { echo "  expected exactly one line about the helper; got:" >&2; sed 's/^/    /' "$workdir/run.log" >&2; rc=1; }
    grep -q 'tools/local-llm-helper ' "$workdir/swift.log" \
        && { echo "  pre-push.sh built the helper without the toolchain" >&2; rc=1; }

    # The other direction, so a gate that always skips cannot pass.
    _run "$workdir" installed pre-push.sh
    status=$?
    [ "$status" -eq 0 ] || { echo "  pre-push.sh exited $status with the Metal Toolchain" >&2; rc=1; }
    grep -q 'tools/local-llm-helper build -c release$' "$workdir/swift.log" \
        || { echo "  pre-push.sh did not build the helper with the toolchain installed" >&2; rc=1; }
    rm -rf "$workdir"
    return "$rc"
}

echo "Testing the Metal Toolchain gate of the local model helper"
echo
run_test "the probe reads the component's status" test_probe_reads_the_component_status
run_test "build_release.sh stops with the install command" test_build_release_stops_without_the_toolchain
run_test "run_app.sh stops with the install command" test_run_app_stops_without_the_toolchain
run_test "pre-push.sh skips the helper with one line" test_pre_push_skips_the_helper_with_one_line

echo
if [ "$FAILED" -eq 0 ]; then
    echo "All tests passed."
else
    echo "Some tests FAILED."
fi
exit "$FAILED"
