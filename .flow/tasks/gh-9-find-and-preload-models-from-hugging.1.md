---
satisfies: [R2, R3, R6]
---
# gh-9-find-and-preload-models-from-hugging.1 Hugging Face catalog client with recorded fixtures

## Description
Build the Hugging Face catalog client the browser will use: the two API calls from the spec's API Contracts, their parsing into variants (with sizes), license and gated flag, and the error mapping. No UI, no settings. Split out first because it is the early proof point: it shows the tag filter and the `?blobs=true` listing find and describe `spert/flix-swissgerman-whisperkit`.

**Size:** M
**Files:** `app/MeetingTranscriber/Sources/HuggingFaceModelCatalog.swift` (new), `app/MeetingTranscriber/Tests/HuggingFaceModelCatalogTests.swift` (new), `app/MeetingTranscriber/Tests/HuggingFaceLicenseTests.swift` (new), `app/MeetingTranscriber/Tests/HuggingFaceCatalogLiveTests.swift` (new), `app/MeetingTranscriber/Tests/Fixtures/HuggingFace/*.json` (new)
**Touches:** [app/MeetingTranscriber/Sources/HuggingFaceModelCatalog.swift, app/MeetingTranscriber/Tests/HuggingFaceModelCatalogTests.swift, app/MeetingTranscriber/Tests/HuggingFaceLicenseTests.swift, app/MeetingTranscriber/Tests/HuggingFaceCatalogLiveTests.swift, app/MeetingTranscriber/Tests/Fixtures/HuggingFace/**]

### Approach
- Write the tests first (the contract is fixed by the spec's API Contracts and R2/R3/R6), run them red, then implement.
- Types and protocol exactly as named in the spec's API Contracts (`HuggingFaceModelCataloging`, `HuggingFaceModelCatalog`, `HuggingFaceModelSummary`, `HuggingFaceRepositoryListing`, `HuggingFaceModelVariant`, `HuggingFaceLicense`, `HuggingFaceCatalogError`). All value types `Equatable, Sendable`; summary and variant `Identifiable` (id = repo id / variant name). `HuggingFaceLicense` may live in the same file; SwiftLint `file_name` only needs the file's namesake type.
- Inject the session like `OpenAIProtocolGenerator` does (`Sources/OpenAIProtocolGenerator.swift:36-46`, `session: URLSession = .shared`). Build URLs with `URLComponents`/query items; the repository path is `api/models/<owner>/<name>` built only after `AppSettings.isValidRepoID` (`Sources/AppSettings+WhisperKitModel.swift:107-126`) accepts the id; otherwise throw `.invalidRepository` with no request. `timeoutInterval` 20 s, `Accept: application/json`, bearer header only for a non-empty trimmed token.
- Variant rule: group `siblings` by first path component (paths with at least two components); a folder is a variant when every `"\(bundle).mlmodelc/\(file)"` for `WhisperKitLocalSnapshot.requiredBundles` × `requiredFiles` (`Sources/WhisperKitLocalSnapshot.swift:31-40`) is present under it and `AppSettings.isValidVariant(folder)`; `sizeBytes` = sum of all file sizes under the folder, nil if any file there lacks `size`. Variants sorted by name. Search results keep API order; drop ids failing `isValidRepoID`.
- License: `cardData.license` (string, or first of an array) → for `other` prefer `cardData.license_name` → else first `license:<id>` tag → else nil. Label: `apache-2.0` → "Apache 2.0", `mit` → "MIT", ids starting `cc-` → "CC " + the non-version components joined with "-" and uppercased + " " + the version component (first component starting with a digit), e.g. `cc-by-nc-sa-4.0` → "CC BY-NC-SA 4.0"; anything else verbatim. Non-commercial when any `-`-separated component of the id/name equals `nc`. Display text = label + " — non-commercial" when non-commercial.
- Errors: map per the spec's API Contracts; any `URLError` except `.cancelled` → `.unreachable`; `URLError(.cancelled)` and `CancellationError` → rethrow `CancellationError`; JSON decode failure → `.malformedResponse`. `message` texts (one line each): unreachable "Cannot reach Hugging Face. Models already on this Mac keep working."; refused "Hugging Face refused the request: the repository is private or does not exist, or the token in Settings was not accepted."; not found "Hugging Face has no such repository."; rate limited "Hugging Face is limiting requests. Try again in a minute."; unexpected status "Hugging Face answered with HTTP <n>."; malformed "Hugging Face sent a response this app cannot read."; invalid repository "Not a valid Hugging Face repository name.".
- Logging: `Logger(subsystem: AppPaths.logSubsystem, category: "HuggingFaceModelCatalog")`; log only the status code or error type (`.public`); never the token, the query or a body (R6).
- Fixtures, recorded anonymously with curl into `Tests/Fixtures/HuggingFace/` (the folder is already excluded from the test target, `Package.swift` `exclude: ["Fixtures", …]`; load with `fixtureURL("HuggingFace/<name>")`, `Tests/TestHelpers.swift:78`):
  - `search-swiss.json` ← `https://huggingface.co/api/models?search=swiss&filter=whisperkit&sort=downloads&direction=-1&limit=20`
  - `repo-spert-flix-swissgerman-whisperkit.json` ← `https://huggingface.co/api/models/spert/flix-swissgerman-whisperkit?blobs=true`
  - `repo-gcoli-whisper-large-v3-swiss-german-coreml.json` ← `https://huggingface.co/api/models/gcoli/whisper-large-v3-swiss-german-coreml?blobs=true`
  - `repo-gated-derived.json` — the spert file with `"gated": "manual"`, hand-derived (say so in the test's doc comment).
  Other edge shapes (a folder missing one required file, an invalid folder name, an id failing `isValidRepoID`, a license array, a tag-only license, no license) are small inline JSON strings in the tests.
- Tests with `MockURLProtocol` (`Tests/MockURLProtocol.swift`; wiring as in `Tests/OpenAIProtocolGeneratorTests.swift:162-180`: ephemeral configuration, `protocolClasses`, clear all handlers in `tearDown`). Pin: exact request path, query items and header presence for nil / "" / "  " / "abc" tokens; spert → exactly one variant `flix-swissgerman-large-v3_8bit` with `sizeBytes == 1_627_283_096`, license "Apache 2.0", not non-commercial, not gated; gcoli → no variants, license from `license_name`, non-commercial; gated fixture → `isGated`; status 401/403/404/429/500, transport error, cancellation, garbage body; invalid repo id makes no request.
- `HuggingFaceLicenseTests`: the label and non-commercial rules as a table of cases.
- `HuggingFaceCatalogLiveTests`: `XCTSkipUnless(ProcessInfo.processInfo.environment["MEETINGTRANSCRIBER_HF_LIVE_TESTS"] == "1")`, then the real search "swiss" contains `spert/flix-swissgerman-whisperkit` and the real listing has `flix-swissgerman-large-v3_8bit` with a size over 1 GB and label "Apache 2.0". Pattern for opt-in env gating: `Tests/WhisperKitCustomModelSmokeTests.swift:1-25`.

### Investigation targets
**Required** (read before coding):
- `app/MeetingTranscriber/Sources/OpenAIProtocolGenerator.swift:30-60` — session injection and HTTP status handling style
- `app/MeetingTranscriber/Tests/OpenAIProtocolGeneratorTests.swift:160-240` — MockURLProtocol wiring
- `app/MeetingTranscriber/Sources/WhisperKitLocalSnapshot.swift:24-118` — required bundles/files reused for the variant rule
- `app/MeetingTranscriber/Sources/AppSettings+WhisperKitModel.swift:107-126` — repo id and variant validation

**Optional** (reference as needed):
- `app/MeetingTranscriber/Tests/MockURLProtocol.swift` — handler API
- `app/MeetingTranscriber/Tests/TestHelpers.swift:78-83` — `fixtureURL`

### Key context
- Measured 2026-10-06: an unknown repository answers 401 (not 404) to anonymous calls; a search with an invalid bearer token still answers 200. Both are why 401/403 read as "private, missing or token refused".
- `MockURLProtocol` uses static handlers; keep all tests that set them in one XCTestCase class (SwiftLint `single_test_class` also requires one class per file).
- SwiftLint runs `--strict` (warnings fail): mind `force_unwrapping`, `discouraged_optional_collection`, `file_name`, `function_body_length` 60.
- No `#if !APPSTORE`: the sandboxed build has `com.apple.security.network.client`.

## Acceptance
- [ ] `HuggingFaceModelCatalogTests` and `HuggingFaceLicenseTests` pass from recorded fixtures with no network access, and each fails when its rule is broken (checked by temporarily breaking the variant rule and the non-commercial rule).
- [ ] The spert fixture yields exactly `flix-swissgerman-large-v3_8bit` with 1,627,283,096 bytes and "Apache 2.0"; the gcoli fixture yields no variant and a non-commercial license.
- [ ] Requests carry `Authorization: Bearer <token>` only for a non-empty trimmed token; an invalid repo id sends no request.
- [ ] `MEETINGTRANSCRIBER_HF_LIVE_TESTS=1 … --filter HuggingFaceCatalogLiveTests` passes against the live API (run once by the worker; result in the done summary); without the variable it is skipped.
- [ ] `cd app/MeetingTranscriber && CFFIXED_USER_HOME=/private/tmp/gh9-t1-home swift test --parallel --filter HuggingFace > /private/tmp/gh9-t1.log 2>&1` green (read the log, never pipe the run); `./scripts/lint.sh` clean with the pinned SwiftFormat 0.63.0 / SwiftLint 0.65.1 from `scripts/tool-versions.sh` (not installed globally: fetch the pinned release assets into a temp dir, verify the SHA-256, run with that dir first on `PATH`); `swift build -c release` clean.


## Done summary
TBD

## Evidence
- Commits:
- Tests:
- PRs:
