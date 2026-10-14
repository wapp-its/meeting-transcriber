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
Added `HuggingFaceModelCatalog`, the client for the two Hugging Face Hub API calls the model browser needs: a `whisperkit`-tagged search and a repository listing with sizes, parsed into loadable variants, a labelled license with a non-commercial mark, the gated flag, and the error mapping from the spec's API Contracts. It runs against fixtures recorded with curl. The early proof point holds: the live API finds `spert/flix-swissgerman-whisperkit` and lists `flix-swissgerman-large-v3_8bit` (1,627,283,096 bytes, "Apache 2.0").

stage: impl-review - ran [e8937d79..7fabb21e] SHIP round 1, 0 findings (codex gpt-5.6-sol xhigh, 3-reviewer panel; receipt /tmp/impl-review-receipt-0c368c08d3d4-gh-9-find-and-preload-models-from-hugging.1.json). Integration: lane commit f8b8bb69 cherry-picked onto e8937d79 as 7fabb21e; bookkeeping b49c9e04.

Tier: implementer - opus at xhigh (explicit invocation) (model: claude-opus-5-5)

### Evidence (all measured)

- baseline: green via handoff (conductor's spec-base run at a971da58, 137/137; no path changed since). Lint baseline was run anyway: 0 violations.
- Red first: the tests were written before the source and failed to compile (`cannot find type 'HuggingFaceModelCatalog'`).
- `cd app/MeetingTranscriber && CFFIXED_USER_HOME=/private/tmp/gh9-t1-home swift test --parallel --filter HuggingFace > /private/tmp/gh9-t1.log 2>&1`: exit 0, 37 tests (17 `HuggingFaceModelCatalogTests`, 1 `HuggingFaceLicenseTests`, 2 live tests skipped, 17 existing token tests). No environmental failures in this filter.
- Live: `MEETINGTRANSCRIBER_HF_LIVE_TESTS=1 … swift test --filter HuggingFaceCatalogLiveTests > /private/tmp/gh9-live.log`: exit 0, both passed against huggingface.co (0.28 s and 0.11 s). Without the variable both are reported `skipped`.
- Mutation check (AC 1): with the folder-completeness check replaced by `!files.isEmpty`, `testGcoliHasNoLoadableVariantAndANonCommercialLicense` and `testAVariantIsAValidFolderHoldingEveryRequiredFile` go red. With the `nc` rule changed from component to substring, `testLabelAndNonCommercialMark` goes red ("unc-research"). After each break the source was restored byte-identical (`cmp`).
- `PATH=/private/tmp/gh9tick/lint-bin:$PATH ./scripts/lint.sh`: exit 0, 0/769 files need formatting, 0 violations.
- `swift build -c release`: exit 0.
- CI-only `swiftlint analyze --strict`, run over a clean `xcodebuild build-for-testing` log: 0 violations in the new files. 2 hits that predate this task are in `Sources/RecordingProvider.swift:144,146` (`unused_declaration`). That file is untouched here and came in with the gh-60 merge. The PR's `analyze` job will fail on them unless they are fixed on wapp/main (noted in NOTES_DIR).
- The error cases R2/R3/R6 name have one test each: 401/403 refused, 404, 429, 500, transport failure, cancellation (a real `Task.cancel()` on an in-flight request), unreadable body, invalid repository id (no request sent), and bearer only for a non-empty trimmed token (nil, "", "  ", "abc", " abc\n", on both calls).

### Choices

- DECIDED (rule 1): the commit carries a `Task:` trailer, as the fork's gh-10 commits on wapp/main do and as worker.md asks. Neither the commit message nor the code names a fork issue number.
- DECIDED (rule 6): `HuggingFaceModelSummary.downloads` is `Int?`, so nil when the API leaves the count out. It is not defaulted to 0; task .3 decides how to show a missing count.
- DECIDED (rule 6): the listing's `id` is the requested repository id, not the response's `id` field. The two are equal for every id the search returns, and this avoids a second validation path.
- DECIDED (rule 6): `modelCardURL` is a stored, non-optional `URL` (`https://huggingface.co/<id>`) that the catalog builds.
- DECIDED (rule 6): a `+` in the search query is sent as `%2B`. URLComponents leaves `+` alone, and form decoding reads it as a space. `testSearchSendsTheQueryAsTyped` pins this.
- DECIDED (rule 6): license selection works the same whether `other` comes from the card or from a `license:` tag: in both cases `license_name` is preferred. Known labels, the `cc-` prefix and the `nc` component match case-insensitively. An unknown id is shown as written.
- DECIDED (rule 6): a listing without `siblings` counts as a malformed response; `tags`, `cardData` and `gated` are optional. Otherwise a broken response would read as "No variant this app can load".
- DECIDED (rule 6): only HTTP 200 counts as success (spec: "other non-200"). A non-HTTP response maps to `.malformedResponse`. Any non-cancellation transport error, `URLError` or not, maps to `.unreachable`.
- DECIDED (rule 6): log lines carry only the call kind ("search"/"listing") and the HTTP status or error type, at `.warning` level. The repository id is not logged either, because a private repository's name may be sensitive.
- DECIDED (rule 6): there is no redirect guard for the bearer token, unlike `RemoteVocabularyFetcher`. The host is fixed to huggingface.co, which the token belongs to. gh-10 needs its guard because a URL the user types can redirect anywhere. Worth a reviewer's glance, since the decision concerns where the token can travel.
- DECIDED (rule 6): the unit tests hold the client as `any HuggingFaceModelCataloging`. Without a caller through the protocol, CI's `unused_declaration` flagged both protocol requirements (measured locally).

### Follow-ups (not built)

- `Sources/RecordingProvider.swift:144,146` unused declarations break CI's `analyze` job at the spec base (this predates gh-9).

stage: plan-sync - skipped(config: planSync.enabled != true)
## Evidence
- Commits: 7fabb21ed91bccc3e6206788a4700e0f187d14a5, b49c9e04948509f4c940cda4fd3d06a5f8462566
- Tests: cd app/MeetingTranscriber && CFFIXED_USER_HOME=/private/tmp/gh9-t1-home swift test --parallel --filter HuggingFace > /private/tmp/gh9-t1.log 2>&1 (exit 0, 37 tests: 17 HuggingFaceModelCatalogTests, 1 HuggingFaceLicenseTests, 2 HuggingFaceCatalogLiveTests skipped, 17 existing token tests), cd app/MeetingTranscriber && MEETINGTRANSCRIBER_HF_LIVE_TESTS=1 CFFIXED_USER_HOME=/private/tmp/gh9-t1-home swift test --filter HuggingFaceCatalogLiveTests > /private/tmp/gh9-live.log 2>&1 (exit 0, 2 passed against huggingface.co; without the variable 2 skipped), PATH=/private/tmp/gh9tick/lint-bin:$PATH ./scripts/lint.sh (exit 0, SwiftFormat 0.63.0 0/769 need formatting, SwiftLint 0.65.1 0 violations), cd app/MeetingTranscriber && swift build -c release (exit 0), xcodebuild clean build-for-testing + swiftlint analyze --strict (0 violations in the new files; 2 pre-existing unused_declaration hits in Sources/RecordingProvider.swift:144,146, untouched), mutation check: variant completeness rule broken -> 2 catalog tests red; nc-component rule broken -> license test red; source restored byte-identical, integrated at b49c9e04948509f4c940cda4fd3d06a5f8462566: cd app/MeetingTranscriber && CFFIXED_USER_HOME=/private/tmp/gh9-t1-home swift test --parallel --filter 'HuggingFace' (exit 0, no failures; parallel mode prints failures only); PATH=/private/tmp/gh9tick/lint-bin:$PATH ./scripts/lint.sh (exit 0, 0 violations)
- PRs: