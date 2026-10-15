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
The Homebrew builds (`run_app.sh` and `build_release.sh`) now build the local model helper in release mode. They put the helper and every SwiftPM resource bundle its build produces (MLX's shaders, swift-transformers_Hub, swift-crypto_Crypto) into `Contents/Helpers`, sign them before the outer bundle (Hardened Runtime on the helper always, plus a timestamp in the notarized branch) and verify them (as of fix pass 1). The helper's licence texts go into `Contents/Resources/licenses` and THIRD-PARTY-NOTICES.md. The App Store build neither builds nor contains the helper. Without the Metal Toolchain, both Homebrew builds stop with the install command and `pre-push.sh` skips the helper with one line. The new `scripts/local-llm-bundle-check.sh` proves the bundled helper's selftest passes from inside the signed app.

baseline: green via handoff (verified at 6dadc040; only .flow/ changed between it and the base 64689dfd)

stage: impl-review - skipped(policy: parallel-wave - conductor owns the gate)

Tier: implementer - opus (explicit invocation) (model: claude-opus-5-5)

### Acceptance

| AC | Evidence |
|---|---|
| 1 `run_app.sh --build-only` + bundle check | rc=0. Helper and shader bundle are in `Contents/Helpers`, signed with Apple Development, helper flags `0x10000(runtime)`, no entitlements. `local-llm-bundle-check.sh` rc=0 (`SELFTEST OK`, `local-llm-bundle-check: OK`) |
| 2 `build_release.sh --no-notarize` | rc=0, same layout, bundle check rc=0. Notarized branch: `sign_local_llm_helper "$APP_BUNDLE" "$DEVELOPER_ID" --timestamp` runs after the dylib loop and before `prepare_signing` and the outer sign. Simulated with an Apple Development identity and a codesign wrapper that dropped only `--timestamp`. The call log shows shader bundle, then helper `--options runtime --timestamp`, then outer. Bundle check rc=0 with flags `runtime` |
| 3 `--appstore --no-notarize` | rc=0 with `xcodebuild` stubbed to report the toolchain uninstalled. No `Contents/Helpers`, no helper licences |
| 4 without the Metal Toolchain | `xcodebuild` stubbed on PATH. `build_release.sh --no-notarize` rc=1 at Step 1 with `xcodebuild -downloadComponent MetalToolchain`. `run_app.sh --build-only` rc=1, same message. `pre-push.sh` rc=0 with one skip line. Pinned by `scripts/tests/test_local_llm_helper_toolchain.sh` (probe table, both builds stop before any `swift` call, pre-push skip and build). The test fails if `require_metal_toolchain` is short-circuited |
| 5 licences | 13 helper texts copied from the helper's checkouts into `Contents/Resources/licenses`: mlx-swift (+ vendored MLX, mlx-c, json, metal-cpp), mlx-swift-lm, swift-transformers and their transitive deps. Each is described in THIRD-PARTY-NOTICES.md "Local model helper (Homebrew build only)" |

The real builds ran before the final edits, which changed only comments, the test harness comment and one error-message string. The shell tests and lint ran again after those edits.

### Gates

- `flowctl gate classify` reported FULL (THIRD-PARTY-NOTICES.md is unmatched), so the focused commands ran.
- `scripts/tests/test_*.sh`: 17 of 18 rc=0. `test_mt_cli_tests_are_compiled.sh` rc=1 is **inherited**: it is also rc=1 at the base 64689dfd. The cause is that `ci.yml` has no job running `tools/local-llm-helper`'s tests (task .1). The fix needs `.github/**`, which is outside this task.
- The two touched test files pass under /bin/bash 3.2 and bash 5.
- `scripts/lint.sh` with the pinned tools: rc=0.
- `shellcheck -S warning`: clean.

### Decisions

- **Helper location `Contents/Helpers` (rule 6, measured).** MLX finds its shader bundle through the main bundle. In `Contents/MacOS` that is the .app, and the selftest traps with rc 133, "Unable to create stream". It passes in `Contents/Helpers`. Recorded in the `scripts/lib/local-llm-helper.sh` header.
- **Toolchain probe override for tests: a PATH stub of `xcodebuild` (rule 6).** No environment override exists in production that could be left set by accident. Recorded at `metal_toolchain_installed`.
- **Bundle check output (rule 6).** The check:
  - takes an optional bundle path and defaults to the dev bundle;
  - prints one line per check, the selftest's lines, then `local-llm-bundle-check: OK`, or `FAIL: <what>` on stderr with exit 1;
  - runs the selftest from an empty working directory, so MLX's working-directory fallback cannot produce a pass;
  - has no negative selftest, because a helper without shaders traps and would leave a crash report on every run, so the shader file's presence is checked instead.

  Recorded in the script header.
- **Helper built before the app (rule 6).** A machine without the toolchain then fails fast, before the app's compile.
- **Failure policy is fatal in both Homebrew scripts (rule 6).** This differs from localvqe, which is non-fatal in `run_app.sh`. The reason: mt-update installs through `run_app.sh`, and a bundle without the helper would have a provider that never works.
- **Non-notarized `build_release.sh` branch does not pre-sign the helper (rule 1, deviates from the task text).** It signs with `--deep --force`, which re-signs nested code. Measured: the runtime flag is dropped and the app's audio-input entitlement is added to the helper. That branch verifies the helper instead. Its notarized branch and `run_app.sh` sign explicitly.
- **Hardened Runtime on the helper in every explicit signing, not only the notarized one (rule 5).**
  - Switch point: `sign_local_llm_helper` in `scripts/lib/signing.sh`.
  - Pinning test: `scripts/local-llm-bundle-check.sh` prints `flags=0x10000(runtime)` and the selftest passes under it.
  - Assumption: MLX needs no entitlement under Hardened Runtime. Measured with an Apple Development certificate. Notarization itself was not run.
- **`sign_local_llm_helper` lives in `signing.sh` (rule 1).** `test_signing_resign.sh::test_only_the_build_scripts_name_a_certificate` permits `codesign --sign` only there and in the two build scripts. `profile_authorised_leaves` and `leaf_is_authorised` are unchanged.
- **Licence texts come from the helper's checkouts (rule 1).** `licenses/` ships in every bundle, and only Homebrew has the helper. The copy uses `install_local_llm_helper_licenses` in `scripts/lib/bundle-licenses.sh`, and runs before the helper copy so no bundle carries the helper without its notices (rule 6).
- **Transitive components attributed per the Scope rule in THIRD-PARTY-NOTICES.md (rule 1).** swift-collections, swift-numerics and {fmt} carry runtime-library or binary exceptions. swift-syntax and swift-asn1 are resolved but not shipped.
- **Pin-coverage refusal (rule 1, the bundle-licenses.sh principle that no list may silently fall behind).** The build fails when `tools/local-llm-helper/Package.resolved` pins a package that is neither attributed nor listed as needing no notice.
- **`lint.sh` covers the helper for SwiftFormat only (rule 1).** SwiftLint reads `.swiftlint.yml`, which is outside Touches.

### Follow-ups (not done; outside Touches)

1. `ci.yml` needs a test job for `tools/local-llm-helper`, on a runner with the Metal Toolchain. Until then the inherited red script test keeps the CI status red.
2. Add the two helper dirs to `.swiftlint.yml` `included`.
3. The release workflow, the self-hosted runner and the mt-update build machine now need the Metal Toolchain.
4. The helper links `@rpath/libswiftCompatibilitySpan.dylib`. It may not launch before macOS 26 unless that dylib is bundled or the deployment target is adjusted. Unverified.
5. The helper links Hub, HuggingFace, EventSource and Network.framework (relevant to task .7's no-network check).
6. The helper README's lint note is now half true.
7. The selftest traps instead of failing cleanly without shaders.
8. THIRD-PARTY-NOTICES lists FluidAudio 0.15.6, but the app pins 0.17.4 (pre-existing).

No user-facing route to a mapped feature changed.

### Fix pass 1

Commits `6641078d..131d45b6`: `a6c911d2` fixes finding 1, and `131d45b6` fixes a second defect that the requested re-run exposed.

**Finding 1 (P1), fixed in `a6c911d2`.**

- Before the fix, measured on the dev bundle: `check` on a model folder whose tokenizer_config.json has no `tokenizer_class` exited 133 with "unable to find bundle named swift-transformers_Hub".
- `install_local_llm_helper` now copies every `*.bundle` in the build's bin directory, not a list of names. Before copying it clears the helper and every `*.bundle` an earlier run left in `Contents/Helpers`.
- `sign_local_llm_helper` signs each bundle before the helper.
- `verify_local_llm_helper` verifies each bundle and requires the shader bundle.
- `local_llm_helper_bin_dir` is the one place that asks SwiftPM for the bin path. The build and the bundle check both use it.
- `scripts/local-llm-bundle-check.sh` now:
  - fails when any bundle the build produced is missing from the app (`FAIL: the build produced <name>, which <dir> lacks`);
  - runs the bundled helper's `check` on a generated folder without `tokenizer_class` (model_type gpt2, no weights). That folder makes swift-transformers resolve its own bundle through `Bundle.module`, so a pass proves a dependency's bundle is found inside the app. This toolchain's generated accessor has no fallback to the build directory, so the app's copy is the only place it can come from.
- THIRD-PARTY-NOTICES.md names the two extra bundles under swift-transformers and swift-crypto.
- New `scripts/tests/test_local_llm_helper_install.sh` pins:
  - copy-all, plus clearing a stale shader file, a dropped bundle and build debris;
  - signing each bundle with the extra flags, then the helper last with `--options runtime`;
  - verifying each bundle, failing on a bad signature of the Hub bundle.

  Mutating install, sign and verify back to the shader bundle only makes all three cases fail.

**Defect found by the re-run, fixed in `131d45b6`.**

- The first `run_app.sh --build-only` of this pass failed (rc 1) with "Permission denied" on `licenses/mlx-swift-LICENSE.txt`.
- Cause: SwiftPM checkouts are read-only (0444), and `cp` carried that mode into the bundle. `run_app.sh` assembles in place, so every build after the first failed, including mt-update's.
- Fix: the licence texts are now installed with `install -m 0644`. The new licence case in the install test runs the install twice from read-only stand-ins. Mutating back to `cp` fails it.

**Finding 2 (P2), declined.** The commit body of `a6c911d2` carries the exact `Declined #2` line. Ad-hoc signing of the helper when no certificate is present is added below as follow-up 9.

**Re-run results (on the tree committed as `131d45b6`):**

| Run | Result |
|---|---|
| `./scripts/run_app.sh --build-only` | rc=0 (rerun after the fix, over the read-only copies the previous build left). "+ 3 resource bundles", helper `flags=0x10000(runtime)` |
| bundle check, dev bundle | rc=0: all 3 bundles present, `SELFTEST OK`, tokenizer loaded through the Hub bundle |
| bundle check, copy without the Hub bundle | rc=1, `FAIL: the build produced swift-transformers_Hub.bundle, which .../Contents/Helpers lacks` |
| `./scripts/build_release.sh --no-notarize` + bundle check | rc=0 / rc=0 (helper `flags=0x0` from `--deep`, as before) |
| notarized branch, simulated | each bundle `--timestamp`, then the helper `--options runtime --timestamp`, then the outer bundle; stops at Step 5 for missing credentials as expected. Bundle check rc=0, flags `runtime` |
| `scripts/tests/test_*.sh` | 18 of 19 rc=0; `test_mt_cli_tests_are_compiled.sh` rc=1, inherited and unchanged |
| helper tests under /bin/bash 3.2 | rc=0 |
| shellcheck `-S warning`, `bash -n` (3.2) | clean |
| `./scripts/lint.sh`, pinned tools | rc=0 |

**Decisions in this pass:**

- **Copy every `*.bundle`, not a list of names (rule 6, as the reviewer asked).** Contents/Helpers is documented as holding only this helper, so every bundle in it is the helper's and may be cleared.
- **The bundle check compares with this checkout's build output (rule 6).** It now needs the helper's build directory in the same checkout. It still builds nothing.
- **Live `Bundle.module` probe through `check` on a generated folder (rule 6).** No weights are loaded and nothing is downloaded. A crash, and so a crash report, can only happen when the bundle is broken, and in that case the name comparison usually fails first.
- **Licence texts installed with mode 0644 (rule 1, a defect in this task's own code).**

**Follow-up added:**

9. When no certificate is present, `run_app.sh` leaves the outer bundle unsigned, and the helper and its bundles with it. Ad-hoc signing both would be a hardening change (declined reviewer finding #2).


stage: impl-review - ran [20:01:57Z..20:31:14Z] (model: codex gpt-6-astra xhigh; round 1 three draws correctness SHIP, contracts SHIP, integration NEEDS_WORK with two findings; the validator pass was not run, both findings were verified by hand instead: #1 reproduced and fixed in a6c911d2, #2 declined; round 2 one reviewer, resumed session) - SHIP
stage: wave-join - ran (fast-forward 6641078d then 131d45b6 onto the spec branch; evidence SHAs unchanged)
stage: conductor-verify - ran (script regression tests, bash 3.2 syntax, shellcheck, git diff --check on the integrated head; the real builds and bundle checks ran in the lane at the same head 131d45b6)

Open item for the person (outside every task of this spec): `scripts/tests/test_mt_cli_tests_are_compiled.sh` is red since task .1 because `.github/workflows/ci.yml` runs no `swift test` for `tools/local-llm-helper`; the fix is a ci.yml job on a runner with the Metal Toolchain, and no task declares `.github/**`.

stage: plan-sync - skipped(config: planSync.enabled != true)
## Evidence
- Commits: fe7980c1c245cf736e48032d6eff749c7b8095d9, 3c865c6bb0a1eea73aa1cbf85483fb913f0cb91c, f85ff2b9bb4695e2070065625e1bfc9f6b47aba0, 6641078df8f412e464ca688583e4e0c1ac77f98c, a6c911d2fce5330283912e32f0285a4a179930e2, 131d45b6f11a2f7402f22fdb28471c48d4ba66b9
- Tests: ./scripts/run_app.sh --build-only (rc=0; helper in Contents/Helpers, flags=0x10000(runtime), Apple Development), ./scripts/local-llm-bundle-check.sh on the dev bundle (rc=0; SELFTEST OK, local-llm-bundle-check: OK), ./scripts/build_release.sh --no-notarize (rc=0) + ./scripts/local-llm-bundle-check.sh .build/release/MeetingTranscriber.app (rc=0; flags=0x0 from --deep, as expected), ./scripts/build_release.sh notarized branch, simulated: DEVELOPER_ID=Apple Development hash, codesign wrapper dropping only --timestamp (helper signed --options runtime --timestamp before the outer bundle; stopped at Step 5 for missing credentials as expected) + bundle check (rc=0; flags=0x10000(runtime)), ./scripts/build_release.sh --appstore --no-notarize with xcodebuild stubbed to report the Metal Toolchain uninstalled (rc=0; no Contents/Helpers, no helper licences), xcodebuild stubbed uninstalled: build_release.sh --no-notarize (rc=1, install command at Step 1), run_app.sh --build-only (rc=1, install command), pre-push.sh (rc=0, one skip line), bundle check negative cases: shader bundle moved aside (rc=1, FAIL: no shader bundle), nonexistent bundle (rc=1), for t in scripts/tests/test_*.sh: 17/18 rc=0; test_mt_cli_tests_are_compiled.sh rc=1, inherited (also rc=1 at base 64689dfd: ci.yml has no job for tools/local-llm-helper tests), scripts/tests/test_local_llm_helper_toolchain.sh and test_signing_identity_choice.sh under /bin/bash 3.2 (rc=0) and bash 5 (rc=0), ./scripts/lint.sh with pinned SwiftFormat 0.63.0 / SwiftLint 0.65.1 (rc=0; 0 violations in 870 files), shellcheck -S warning -x on the new and changed scripts (rc=0); bash -n under /bin/bash 3.2 on all changed scripts (clean), GATE: flowctl gate classify --base 64689dfd -> FULL (THIRD-PARTY-NOTICES.md unmatched); focused Quick commands above ran, fix pass 1: ./scripts/run_app.sh --build-only (first attempt rc=1: Permission denied on a read-only licence copy from the previous in-place build, fixed in 131d45b6; rerun rc=0, + 3 resource bundles, flags=0x10000(runtime)), fix pass 1: ./scripts/local-llm-bundle-check.sh on the dev bundle (rc=0; all 3 build bundles present, SELFTEST OK, check on a folder without tokenizer_class loads the tokenizer), fix pass 1: before the fix, the dev bundle helper: check on a folder without tokenizer_class rc=133 (Fatal error: unable to find bundle named swift-transformers_Hub), fix pass 1: bundle check on a copy without swift-transformers_Hub.bundle (rc=1; FAIL: the build produced swift-transformers_Hub.bundle, which .../Contents/Helpers lacks), fix pass 1: ./scripts/build_release.sh --no-notarize (rc=0; + 3 resource bundles) + bundle check on .build/release/MeetingTranscriber.app (rc=0), fix pass 1: build_release.sh notarized branch simulated (Apple Development identity, codesign wrapper dropping only --timestamp): 3 bundles signed --timestamp, then helper --options runtime --timestamp, then the outer bundle; stopped at Step 5 for missing credentials as expected; bundle check rc=0, fix pass 1: scripts/tests/test_local_llm_helper_install.sh (rc=0, 4 cases; bash 3.2 rc=0); mutation to a shader-only copy/sign/verify fails 3 cases, mutation back to cp fails the licence case, fix pass 1: for t in scripts/tests/test_*.sh: 18/19 rc=0; test_mt_cli_tests_are_compiled.sh rc=1, inherited (unchanged), fix pass 1: shellcheck -S warning on changed scripts (rc=0); bash -n under /bin/bash 3.2 (clean); ./scripts/lint.sh with pinned tools (rc=0, 0 violations in 870 files), conductor verify at 131d45b6: scripts/tests/test_*.sh 18/19 rc=0 (test_mt_cli_tests_are_compiled.sh red, inherited from task .1); bash -n under /bin/bash 3.2 clean; git diff --check clean
- PRs: