#!/usr/bin/env bash
# Installs the third-party licence texts every shipped bundle has to carry.
#
# The app statically links third-party source (WhisperKit, FluidAudio) and
# bundles third-party weights (LocalVQE), so the .app redistributes all of them.
# Apache-2.0 section 4a wants a copy of the License with any redistribution and
# 4d wants an existing NOTICE propagated; MIT wants its copyright and permission
# notice in all copies, and a binary is a copy. Nothing about that is visible at
# link time, which is exactly why it needs a build step rather than good
# intentions.
#
# The loop copies whatever `licenses/` holds instead of naming components, so a
# new dependency is attributed by dropping its licence file into that directory:
# no build script has to learn about it, and there is no per-component list that
# can silently fall behind the one in Package.swift.
#
# This is why the licence copy no longer rides along with the LocalVQE model
# install. Installing it here strengthens the property that helper's header
# claims: licences land unconditionally from a directory, not as a side effect of
# a model download that a caller is allowed to fail past.
#
# Source this, don't execute it.

# Copies every licence text in the repo's licenses/ directory into
# <resources-dir>/licenses/. Fatal on failure under `set -e`: a bundle that
# redistributes the code without the notices is not one to ship.
install_third_party_licenses() {
    local resources_dir="$1"
    local lib_dir licenses_src dest
    local -a licence_files
    lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    licenses_src="$lib_dir/../../licenses"
    dest="$resources_dir/licenses"

    # Collected rather than globbed straight into cp so an empty directory is a
    # hard stop. Unmatched, the glob would reach cp as a literal path and the
    # error would read like a missing file instead of "this bundle attributes
    # nothing".
    licence_files=("$licenses_src"/*.txt)
    if [ ! -e "${licence_files[0]}" ]; then
        echo "  ERROR: no licence texts in $licenses_src" >&2
        return 1
    fi

    # Anything outside the glob would be skipped in silence, and the directory
    # would still be non-empty so the check above would not catch it. Upstream
    # projects commonly ship LICENSE.md, so dropping one in unrenamed is the
    # natural mistake: it has to fail the build rather than bundle nothing.
    local candidate
    for candidate in "$licenses_src"/*; do
        case "$candidate" in
            *.txt) ;;
            *)
                echo "  ERROR: $candidate is not a .txt and would not be bundled" >&2
                return 1
                ;;
        esac
    done

    mkdir -p "$dest"
    cp "${licence_files[@]}" "$dest/"

    echo "  Third-party licenses: $dest (${#licence_files[@]} files)"
}

# The local model helper (lib/local-llm-helper.sh) is its own SwiftPM package
# and ships only in the Homebrew bundle, so its notices cannot live in
# licenses/, which every bundle gets. They come from the helper's own resolved
# checkouts instead, so the text in the bundle is always the one of the version
# that was built.
#
# One entry per text: <path under tools/local-llm-helper/.build/checkouts>
# <file name in Contents/Resources/licenses>. The mlx-swift lines below its
# own cover code it vendors and compiles into the helper. THIRD-PARTY-NOTICES.md
# describes each.
LOCAL_LLM_HELPER_LICENSES="
mlx-swift/LICENSE mlx-swift-LICENSE.txt
mlx-swift/Source/Cmlx/mlx/LICENSE mlx-swift-mlx-LICENSE.txt
mlx-swift/Source/Cmlx/mlx-c/LICENSE mlx-swift-mlx-c-LICENSE.txt
mlx-swift/Source/Cmlx/json/LICENSE.MIT mlx-swift-json-LICENSE.txt
mlx-swift/Source/Cmlx/metal-cpp/LICENSE.txt mlx-swift-metal-cpp-LICENSE.txt
mlx-swift-lm/LICENSE mlx-swift-lm-LICENSE.txt
swift-transformers/LICENSE swift-transformers-LICENSE.txt
swift-jinja/LICENSE swift-jinja-LICENSE.txt
swift-huggingface/LICENSE swift-huggingface-LICENSE.txt
EventSource/LICENSE.md EventSource-LICENSE.txt
yyjson/LICENSE yyjson-LICENSE.txt
swift-crypto/LICENSE.txt swift-crypto-LICENSE.txt
swift-crypto/NOTICE.txt swift-crypto-NOTICE.txt
"

# Pins in the helper's Package.resolved that need no notice in the bundle:
# swift-syntax serves only a compiler macro plugin the helper does not use,
# swift-asn1 is not linked, and swift-collections and swift-numerics are
# Apache-2.0 with the Swift runtime library exception, which waives
# attribution for compiled code.
LOCAL_LLM_HELPER_UNATTRIBUTED_PINS="swift-syntax swift-asn1 swift-collections swift-numerics"

# install_local_llm_helper_licenses <resources-dir> <helper-package-dir>
#
# Copies the texts above into <resources-dir>/licenses/. Fails when a text is
# missing, and when Package.resolved pins a package that is neither attributed
# above nor listed as needing no notice: a list of components is exactly what
# the licenses/ loop exists to avoid, so this one must not fall behind a
# dependency update in silence.
install_local_llm_helper_licenses() {
    local resources_dir="$1" package_dir="$2"
    local checkouts="$package_dir/.build/checkouts" dest="$1/licenses"
    local source_path name pins pin covered count=0

    # Pin identities are lower case, checkout directories keep the repository's
    # case (EventSource), so the comparison is made in lower case.
    pins="$(sed -n 's/.*"identity" : "\([^"]*\)".*/\1/p' "$package_dir/Package.resolved")" || return 1
    [ -n "$pins" ] || { echo "  ERROR: no pins read from $package_dir/Package.resolved" >&2; return 1; }
    covered=" $LOCAL_LLM_HELPER_UNATTRIBUTED_PINS "
    while read -r source_path name; do
        [ -n "$source_path" ] || continue
        covered="$covered${source_path%%/*} "
    done <<< "$LOCAL_LLM_HELPER_LICENSES"
    covered="$(tr '[:upper:]' '[:lower:]' <<< "$covered")"
    while read -r pin; do
        case "$covered" in
            *" $pin "*) ;;
            *)
                echo "  ERROR: the local model helper pins $pin, which has no licence entry in" >&2
                echo "  scripts/lib/bundle-licenses.sh. Attribute it there and in THIRD-PARTY-NOTICES.md." >&2
                return 1
                ;;
        esac
    done <<< "$pins"

    # `install -m 0644` and not `cp`: SwiftPM leaves its checkouts read-only,
    # cp carries that mode into the bundle, and the next in-place assembly
    # (run_app.sh) then cannot overwrite the copy (measured: "Permission
    # denied" on the second build).
    mkdir -p "$dest" || return 1
    while read -r source_path name; do
        [ -n "$source_path" ] || continue
        if [ ! -f "$checkouts/$source_path" ]; then
            echo "  ERROR: licence text not found: $checkouts/$source_path" >&2
            return 1
        fi
        install -m 0644 "$checkouts/$source_path" "$dest/$name" || return 1
        count=$((count + 1))
    done <<< "$LOCAL_LLM_HELPER_LICENSES"

    echo "  Local model helper licenses: $dest ($count files)"
}
