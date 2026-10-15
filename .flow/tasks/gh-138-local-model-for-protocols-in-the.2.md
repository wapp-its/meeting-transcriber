---
satisfies: [R9]
---
# gh-138-local-model-for-protocols-in-the.2 Build scripts: build, embed, sign and check the helper

## Description
Both build scripts build the helper package for the Homebrew app only, put the helper and MLX's shader bundle into the app, sign them, and a bundle check proves the signed helper finds its shaders from inside the bundle. `mt-update` builds the installed app through `run_app.sh --build-only`, so that path matters most.

**Size:** M
**Files:** `scripts/lib/local-llm-helper.sh` (new, shared by both scripts like `scripts/lib/localvqe-resources.sh`), `scripts/build_release.sh`, `scripts/run_app.sh`, `scripts/lib/signing.sh`, `scripts/lib/bundle-licenses.sh`, `scripts/local-llm-bundle-check.sh` (new), `scripts/pre-push.sh`, `THIRD-PARTY-NOTICES.md`
**Touches:** [scripts/**, THIRD-PARTY-NOTICES.md]

### Approach
- `scripts/lib/local-llm-helper.sh`: a function that checks the Metal Toolchain (`xcodebuild -showComponent MetalToolchain`), builds `tools/local-llm-helper` in release, and installs the helper into `Contents/MacOS` (or `Contents/Helpers`, pick one and document it) and `mlx-swift_Cmlx.bundle` where the helper finds it (next to the helper binary, as SwiftPM lays it out). Missing toolchain: fail with a message naming `xcodebuild -downloadComponent MetalToolchain`.
- `build_release.sh`: call it only for the non-`--appstore` variant, after the main binary copy (`scripts/build_release.sh:83-89`). Notarized branch (`:155-196`): sign the helper with `--options runtime --timestamp` before `prepare_signing` and the outer sign; the dylib loop at `:168` does not match a bare executable. Non-notarized branch (`:217-227`) keeps `--deep`.
- `run_app.sh`: call it after the binary copy (`scripts/run_app.sh:73`), before the re-sign at `:122-128`; `--build-only` (used by `mt-update`) must include it.
- Signing: sign the embedded helper explicitly (and the shader bundle) before the outer bundle in both scripts and both release branches: `--options runtime --timestamp` with the Developer ID in the notarized branch, the same identity as the outer bundle elsewhere. Leave `profile_authorised_leaves` / `leaf_is_authorised` in `scripts/lib/signing.sh` unchanged: they match certificate fingerprints in a provisioning profile, not nested executables. Verify the embedded helper itself (`codesign --verify --strict` on the helper path and `codesign -d` showing its flags), since `verify_signing` only checks the outer bundle's entitlement.
- Licences: add mlx-swift, mlx-swift-lm and swift-transformers licence texts through `install_third_party_licenses` and list them in `THIRD-PARTY-NOTICES.md`.
- `scripts/local-llm-bundle-check.sh`: like `scripts/localvqe-bundle-check.sh`, run the bundled helper's `selftest` from a signed app bundle and fail on a missing shader bundle.
- `pre-push.sh` (`scripts/pre-push.sh:42-52`): build the helper package too when the Metal Toolchain is installed; skip with one clear line when it is not, so a machine without it can still push app-only changes.

### Investigation targets
**Required:**
- `scripts/build_release.sh:80-90,155-227` — copy and signing steps
- `scripts/run_app.sh:60-130` — dev bundle assembly and re-sign
- `scripts/lib/signing.sh:60-240` — `prepare_signing` and `verify_signing` (leave the profile/certificate matching unchanged)
- `scripts/localvqe-bundle-check.sh` — the bundle-check pattern

**Optional:**
- `scripts/lib/bundle-licenses.sh` — licence installation

### Key context
- `Homebrew.entitlements` has only the microphone entitlement; whether MLX needs anything under Hardened Runtime is unverified, which is exactly what the bundle check answers.
- The App Store variant must neither build nor contain the helper.
## Acceptance
- [ ] `./scripts/run_app.sh --build-only` produces an app whose bundle contains the helper and the shader bundle, signed; `scripts/local-llm-bundle-check.sh` passes on it.
- [ ] `./scripts/build_release.sh --no-notarize` produces the same layout; its notarized branch signs the helper with Hardened Runtime and a timestamp before the outer bundle (reviewed in the diff; no Developer ID on the build machine).
- [ ] `./scripts/build_release.sh --appstore --no-notarize` produces an app without the helper and needs no Metal Toolchain.
- [ ] Without the Metal Toolchain, both Homebrew builds fail with the install-command message; `pre-push.sh` skips the helper build with one line.
- [ ] Licence texts for the three new dependencies are in the bundle and in `THIRD-PARTY-NOTICES.md`.
## Done summary
TBD

## Evidence
- Commits:
- Tests:
- PRs:
