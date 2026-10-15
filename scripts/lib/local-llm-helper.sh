#!/usr/bin/env bash
# Single source of truth for how the local model helper gets into an app bundle.
#
# The helper (tools/local-llm-helper) is the program the app starts to write a
# protocol with a local MLX model. It is its own SwiftPM package, so the app's
# package never depends on MLX, and only the Homebrew variant carries it: the
# App Store build neither sources this file nor builds the helper. Two scripts
# assemble a Homebrew bundle, build_release.sh and run_app.sh (the one mt-update
# installs the app through), and both go through the functions below so the
# two bundles cannot drift apart. The failure policy is the same in both, unlike
# lib/localvqe-resources.sh: a machine without the Metal Toolchain cannot build
# the helper, and a bundle without it would have a provider that never works.
#
# Layout inside the bundle, decided once here:
#
#   Contents/Helpers/local-llm-helper         the executable
#   Contents/Helpers/mlx-swift_Cmlx.bundle    MLX's compiled Metal shaders
#   Contents/Helpers/<other>.bundle           every other SwiftPM resource
#                                             bundle the build put beside it
#
# Contents/Helpers and not Contents/MacOS, measured: MLX looks for its shader
# bundle in the directory of NSBundle.mainBundle, and an executable in
# Contents/MacOS gets the .app as its main bundle, so MLX searches the app's
# root and Resources, finds nothing, and the selftest dies with "Unable to
# create stream". In Contents/Helpers the main bundle is the directory that
# holds the helper, which is where SwiftPM puts the shader bundle in its own
# build directory too, so the helper finds it exactly as it does there.
#
# Every bundle, not a list of names: a dependency reaches its resources through
# SwiftPM's Bundle.module, which looks in that same directory and stops the
# process when the bundle is not there. Today that is swift-transformers_Hub,
# whose fallback tokenizer configurations a model folder without a
# `tokenizer_class` needs (measured: without the bundle, `check` on such a
# folder dies with "unable to find bundle named swift-transformers_Hub"), and
# swift-crypto_Crypto. A list of names would miss the next dependency's bundle
# the same way. Contents/Helpers holds this helper and nothing else, so every
# bundle in it is the helper's.
#
# Source this, don't execute it.

LOCAL_LLM_HELPER_DIR="Contents/Helpers"
LOCAL_LLM_HELPER_NAME="local-llm-helper"
LOCAL_LLM_SHADER_BUNDLE="mlx-swift_Cmlx.bundle"

_LOCAL_LLM_HELPER_PACKAGE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/tools/local-llm-helper"

# The helper's licence texts are installed with it.
# shellcheck source=bundle-licenses.sh
source "$(dirname "${BASH_SOURCE[0]}")/bundle-licenses.sh"

# Whether Xcode's Metal Toolchain component is installed. It compiles MLX's
# shaders, and SwiftPM fails the helper build without it. `xcrun --find metal`
# is no test for it: that finds a stub either way. Tests replace `xcodebuild`
# through PATH, so there is no override here to leave set by accident.
metal_toolchain_installed() {
    local status
    status="$(xcodebuild -showComponent MetalToolchain 2>/dev/null)" || return 1
    case $'\n'"$status"$'\n' in
        *$'\nStatus: installed\n'*) return 0 ;;
    esac
    return 1
}

# Fails with the install command when the toolchain is missing.
require_metal_toolchain() {
    metal_toolchain_installed && return 0
    echo "  ERROR: Xcode's Metal Toolchain is not installed. The local model helper" >&2
    echo "  needs it to compile MLX's shaders. Install it with:" >&2
    echo "    xcodebuild -downloadComponent MetalToolchain" >&2
    return 1
}

# local_llm_helper_bin_dir [extra swift build flags...]
#
# Prints the directory the release build puts the helper and its resource
# bundles in. Asked of SwiftPM rather than hard-coded: with Swift 6.4,
# `.build/release` is only a link to `.build/out/Products/Release`. Shared with
# scripts/local-llm-bundle-check.sh, which compares an app bundle with it.
local_llm_helper_bin_dir() {
    (cd "$_LOCAL_LLM_HELPER_PACKAGE" && swift build -c release "$@" --show-bin-path)
}

# build_local_llm_helper [extra swift build flags...]
#
# Builds the helper in release and sets LOCAL_LLM_HELPER_BIN_DIR to the
# directory holding the executable and its resource bundles. Always release, in
# both scripts: a debug build fails the 4-bit quantised matrix multiply every
# layer of a quantised model runs (a GPU timeout and wrong numbers, measured).
#
# Every step propagates its own failure, like install_localvqe_resources, so
# the function is safe to call from a condition.
#
# shellcheck disable=SC2034  # LOCAL_LLM_HELPER_BIN_DIR is read by install_local_llm_helper
build_local_llm_helper() {
    local bin_dir
    require_metal_toolchain || return 1
    echo "Building the local model helper (release)..."
    (cd "$_LOCAL_LLM_HELPER_PACKAGE" && swift build -c release "$@") || return 1
    bin_dir="$(local_llm_helper_bin_dir "$@")" || return 1
    if [ ! -x "$bin_dir/$LOCAL_LLM_HELPER_NAME" ] || [ ! -d "$bin_dir/$LOCAL_LLM_SHADER_BUNDLE" ]; then
        echo "  ERROR: the helper build did not produce $LOCAL_LLM_HELPER_NAME and $LOCAL_LLM_SHADER_BUNDLE in ${bin_dir:-<no bin path>}" >&2
        return 1
    fi
    LOCAL_LLM_HELPER_BIN_DIR="$bin_dir"
}

# install_local_llm_helper <app-bundle>
#
# Copies the helper and every resource bundle of its build into the bundle's
# Contents/Helpers, and the licence texts of what it links into
# Contents/Resources/licenses. Needs build_local_llm_helper first.
#
# run_app.sh reassembles its bundle in place, so whatever an earlier run put in
# Contents/Helpers is removed first, every bundle and not only the ones this
# build produced: `cp -R` onto an existing bundle merges into it, which would
# keep shaders of an older MLX, and a bundle a dependency update dropped would
# otherwise stay in the app for good.
install_local_llm_helper() {
    local bundle="$1" dest path count=0
    # Guarded because of the rm below: an empty argument would aim it at /Contents/Helpers.
    [ -n "$bundle" ] || { echo "  ERROR: no app bundle given" >&2; return 1; }
    [ -n "${LOCAL_LLM_HELPER_BIN_DIR:-}" ] || { echo "  ERROR: build_local_llm_helper has not run" >&2; return 1; }
    dest="$bundle/$LOCAL_LLM_HELPER_DIR"

    # Licences first, so no failure further down can leave a bundle that
    # carries the helper without its notices.
    install_local_llm_helper_licenses "$bundle/Contents/Resources" "$_LOCAL_LLM_HELPER_PACKAGE" || return 1

    mkdir -p "$dest" || return 1
    rm -f "${dest:?}/$LOCAL_LLM_HELPER_NAME" || return 1
    for path in "$dest"/*.bundle; do
        [ -e "$path" ] || continue
        rm -rf "${path:?}" || return 1
    done

    cp "$LOCAL_LLM_HELPER_BIN_DIR/$LOCAL_LLM_HELPER_NAME" "$dest/" || return 1
    for path in "$LOCAL_LLM_HELPER_BIN_DIR"/*.bundle; do
        [ -d "$path" ] || continue
        cp -R "$path" "$dest/" || return 1
        count=$((count + 1))
    done

    echo "  Local model helper: $dest/$LOCAL_LLM_HELPER_NAME (+ $count resource bundles)"
}

# Signing them is sign_local_llm_helper in lib/signing.sh, the one place a
# codesign call that names a certificate belongs.

# verify_local_llm_helper <app-bundle>
#
# Call AFTER the outer bundle is signed. verify_signing in lib/signing.sh
# speaks only about the outer bundle's entitlements, so this checks the nested
# signatures themselves, every resource bundle's and the helper's, and prints
# the helper's flags and authority, where a missing `runtime` would show
# before notarization rejects it.
verify_local_llm_helper() {
    local dir="$1/$LOCAL_LLM_HELPER_DIR" path details flags authority
    [ -d "$dir/$LOCAL_LLM_SHADER_BUNDLE" ] || {
        echo "  ERROR: $dir/$LOCAL_LLM_SHADER_BUNDLE is missing" >&2
        return 1
    }
    for path in "$dir"/*.bundle "$dir/$LOCAL_LLM_HELPER_NAME"; do
        codesign --verify --strict "$path" || {
            echo "  ERROR: the signature of $path does not verify" >&2
            return 1
        }
    done
    details="$(codesign -d -vv "$dir/$LOCAL_LLM_HELPER_NAME" 2>&1)" || return 1
    flags="$(sed -n 's/^CodeDirectory .*flags=\([^ ]*\).*/\1/p' <<< "$details")"
    authority="$(awk '/^Authority=/ { print substr($0, 11); exit }' <<< "$details")"
    echo "  Helper signature verified: flags=${flags:-?} authority=${authority:-none (ad hoc)}"
}
