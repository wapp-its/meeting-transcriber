# Start the app at login and date both ends of the not-running notice

## Conversation Evidence

The fork is public, so the owner's turns are paraphrased, not quoted.

> owner (paraphrased, issue body, 2026-10-14): after a Mac restart without a clean shutdown, the app stays off until someone starts it by hand, and no meetings are watched in the meantime. The app is not a login item and has no setting for it.
> owner (paraphrased, issue body, 2026-10-14): the next launch reported the gap, but the second time in the notice has no date, so after a gap of a day or more it reads like zero minutes. The date or the length ("for 2 days") would be clearer.
> owner (paraphrased, issue body, 2026-10-14): `SMAppService.mainApp` can register the app as a login item; mt-update replaces the app bundle at the same path, so check that the login item survives an update.
> owner (paraphrased, issue body, 2026-10-14): tasks: add an "Open at login" setting (on by default, with a question mark), and show the date or the length for the second time in the notice.
> owner (paraphrased, 2026-11-12): picked this issue for a spec.

## Goal & Context

After a Mac restart, the app starts again by itself when the user logs in. In the fork's builds installed in the Applications folder this is on without anyone touching Settings, and the user can switch it off in Settings → General → Startup. When the app did stop without quitting, the notice at the next launch names both ends of the gap with their dates when the gap crosses midnight, so a two-day gap no longer reads like one minute.

Why it matters:

- **A menu bar app that is not running looks like one that is idle.** The point of the app is that it records without being watched; after a restart it watches nothing until someone notices. [paraphrase]
- **The original already built the login item.** Its PR 916 (merged 2026-11-08, from its discussion 796) adds "Launch at login" and "Start watching when the app opens" to Settings → General → Startup, with launch at login off until the user switches it on. It has not reached `wapp/main` yet: the upstream merge is blocked by conflicts, tracked in #211. This spec builds on that code and adds only what the fork wants on top: the default, a launch log line, and the update check. [inferred]
- **The notice comes from the original too** (its PR 704, for its issue 703) and is still the same text there; nothing in the original fixes the missing date. [inferred]

The control is named "Launch at login", the original's label; the issue's "Open at login" means the same. [inferred]

<!-- Source: 0% user / 40% [paraphrase] / 60% [inferred] -->

## Architecture & Data Models

- **The login item itself is the original's code**, arriving with #211: `app/MeetingTranscriber/Sources/LoginItemController.swift` (`LoginItemController` on `SMAppService.mainApp`, the macOS service that registers an app as a login item, behind the `LoginItemRegistering` protocol so tests use a fake) and the Startup section in `Settings/GeneralSettingsView.swift`. The toggle reads the status from macOS and stores nothing. This spec does not change those files. [inferred]
- **One fork-only file holds the default:** `app/MeetingTranscriber/Sources/LoginItemDefault.swift`, a pure decision plus a small launch step. Keeping it in its own file keeps the nightly upstream merge free of conflicts in the original's files. [inferred]
  - Decision inputs: build variant (App Store or not), the running bundle's folder, whether the other Meeting Transcriber copy is installed in `/Applications` (`MeetingTranscriber.app` for the Dev build, `MeetingTranscriber-Dev.app` for the release-named build), whether the default was already applied, and the login item status. [inferred]
  - Decision outputs: register now; nothing to do (already on, or waiting for approval); default already applied; skipped with a reason (App Store build, not in `/Applications`, other copy installed). [inferred]
  - One `UserDefaults` key, `loginItemDefaultApplied` (Bool), outside `AppSettings`. `UserDefaults` is per bundle identifier, so the Dev build (`app.meetingtranscriber.dev`) and the release-named build (`app.meetingtranscriber`) each keep their own key and their own login item. [inferred]
- **The launch step runs once per launch, after launch has finished,** from the app's real entry point (where `AppLauncher.main()` arms the liveness marker, or where auto-watch is scheduled in `MeetingTranscriberApp.init`). It never runs from `AppState.init`, which the unit tests construct, so no test reaches the real `SMAppService` (the same rule the liveness marker follows, `docs/architecture/permissions-lifecycle.md`). [inferred]
- **The App Store variant compiles the register path of the default out** (`#if !APPSTORE`) and only logs `default=skipped-appstore`; the original's toggle stays and works there unchanged. [inferred]
- **The notice** stays a pure text type in `app/MeetingTranscriber/Sources/PreviousExitNotice.swift`; only its date rule changes (R1). [inferred]
- **Docs, same commit:** a row for `LoginItemDefault.swift` in `docs/architecture-macos.md`; in `docs/architecture/permissions-lifecycle.md`, one sentence that the fork's builds start at login by default (a login item acts at login only, not after a crash); one line in `.github/README.md` (the fork's readme) that the fork's builds start at login by default. [inferred]

## API Contracts

None for outside callers: the `/v1` automation API and the debug RPC server do not change. The only new contracts are internal:

- **Launch log line**, once per launch, notice level (info lines are not kept), subsystem `com.meetingtranscriber`, content-free: `login_item status=<enabled|requiresApproval|notRegistered|notFound> default=<registered|already-on|waiting-approval|already-applied|failed|skipped-appstore|skipped-location|skipped-other-copy>`. [inferred]
- **`UserDefaults` key** `loginItemDefaultApplied` (Bool, absent = not applied). [inferred]

## Edge Cases & Constraints

- **Prerequisite: #211 is merged,** so `wapp/main` contains the original's `LoginItemController` and Startup section. If it does not when this spec is built, the build stops and reports; it does not copy or cherry-pick the original's commits. [inferred]
- **First launch after the update** registers the item, and macOS shows its own "Login Item Added" notification once. That is expected and stays. [inferred]
- **Switched off by the user**, in Settings or in System Settings → General → Login Items: the default never applies again, because the key is set. macOS may then report `requiresApproval`; the original's toggle shows that as on with a hint, unchanged. [inferred]
- **A login item works only after login.** A Mac that waits at the login window after a restart watches nothing until the user logs in. [inferred]
- **Starting is not watching.** The app watches after login only when "Start watching when the app opens" (`AppSettings.autoWatch`, off by default) is on; both switches sit together in Startup. This spec does not change that default. [inferred]
- **Silent start needs the grants.** On a machine without the microphone and audio-capture grants, macOS asks for them when watching starts, as the original's readme says. [inferred]
- **Two copies with the same bundle identifier** (the copy in `/Applications` and an end-to-end test copy the e2e scripts deploy to the user's own Applications folder): which one macOS starts at login is not known. The default never registers the e2e copy, because it is not in `/Applications`. [inferred]
- **A login item the user added by hand earlier** (the older login items list) stays; macOS opens one running instance of the app. [inferred]
- **Tests never reach the real service:** unit tests use the fake `LoginItemRegistering`; the launch step is not in `AppState.init`; no `/ui/press` entry for the toggle (the original's rule in `docs/architecture/gui-testing.md`). [inferred]
- **No meeting content** in logs or tests. The log line carries status words only. [inferred]

## Acceptance Criteria

- **R1:** When the stop and the launch fall on different calendar days, the notice dates both times; a same-day notice is unchanged. Reproduction and test first: in `PreviousExitNoticeTests` (en_GB, UTC, Gregorian), stop `2026-03-08T10:52Z` and launch `2026-03-10T10:53Z` must give exactly "It stopped without quitting at about 10:52 on 8 Mar and was not watching for meetings until 10:53 on 10 Mar. Nothing was recorded in between."; today it gives "... until 10:53." and the test fails for that reason. A gap across midnight (23:50 to 00:10 the next day) dates both ends too. The existing test `testAWindowFromAnEarlierDayCarriesTheDate` changes its expected text from "until 14:03." to "until 14:03 on 9 Mar." because this requirement changes it. Errors: a stop time later than the launch time (clock set back) still gives a notice, dated on both ends when the days differ, and never crashes. [paraphrase]
- **R2:** In a non-App-Store build running directly from `/Applications`, the first launch registers the app as a login item when macOS reports it `notRegistered` or `notFound`, and sets `loginItemDefaultApplied`. Every later launch registers nothing, so a user who switched it off stays off. Status `enabled` or `requiresApproval` at that first launch registers nothing and sets the key. Errors: `register()` throws → the content-free log line says `default=failed`, the key is set (no retry on every launch), and the Settings toggle shows off. Test: decision unit tests with the fake registrar over two launches in a row (register called exactly once), plus a second run where the fake reports `notRegistered` after the user switched it off (register not called). [inferred]
- **R3:** The default never registers in these cases, and the toggle starts off as in the original: the App Store build (compiled out); a bundle not directly in `/Applications` (a build folder, the user's own Applications folder, a disk image, the temporary path macOS runs a freshly downloaded app from); the other Meeting Transcriber copy installed in `/Applications`. App Store and location skips leave the key unset, so the default applies once the app runs from `/Applications`; the other-copy skip sets the key, so the default is spent and the user picks in Settings. Errors: none beyond R2's. Test: one decision unit test per case, each asserting register is not called and the key state. [inferred]
- **R4:** Every launch logs the one line from API Contracts with the status macOS reports and what the default step did. Test: a unit test of the line's text for each outcome; live check in R5. Errors: none; reading the status does not throw. [inferred]
- **R5:** The login item survives an mt-update install. Check, run by the agent that lands the PR, after the merge: run mt-update (it installs the Dev app at the same path, `/Applications/MeetingTranscriber-Dev.app`); the launch line shows `status=enabled default=registered` (or `default=already-on`); run mt-update a second time (it rebuilds and replaces the bundle again); the launch line now shows `status=enabled default=already-applied`, read with `/usr/bin/log show --last 15m --predicate 'subsystem == "com.meetingtranscriber"'`. Errors: any other status after the second install → the agent reports the line to the owner and adds no re-register rule (A6). The owner then checks once by hand, not blocking: after one real restart, the app's icon is in the menu bar without a click. [paraphrase]

## Boundaries

- Relaunching the app after a crash while the user stays logged in (a watchdog or a kept-alive agent) is not in this spec; it is an open product decision in `docs/architecture/permissions-lifecycle.md`. [inferred]
- The default of "Start watching when the app opens" is not changed. [inferred]
- A length in the notice ("for 2 days"), and a second place for the notice (a menu item or a `/state` field), are not in this spec. [inferred]
- An "Open Login Items" button and a special hint for `notFound` are not in this spec; the original left them out on purpose. [inferred]
- Re-registering the item after an update, if R5 finds it lost, is not in this spec (A6). [inferred]
- Resolving the upstream merge (#211), including any duplicate auto-watch toggle it leaves, is #211's work, not this spec's. [inferred]
- The default-on login item is fork-only and never goes to the original. Offering the notice fix (R1) to the original is a separate step after the owner's go. [inferred]

## Decision Context

- **D1 · Add a setting that starts the app at login, using `SMAppService.mainApp`.** why: after a restart the app stays off and watches nothing · status: active [owner-stated 2026-10-14, issue body]
- **D2 · The notice's second time gets a date or a length.** why: after a gap of a day or more it reads like zero minutes · status: active [owner-stated 2026-10-14, issue body]
- **D3 · Check that the login item survives an mt-update install.** why: mt-update replaces the bundle at the same path · status: active [owner-stated 2026-10-14, issue body]
- **A1 · Adopt the original's launch-at-login code (its PR 916) through the upstream merge in #211 instead of building a second one.** flip at: #211 stays blocked when this spec is due, and the owner allows copying the original's three commits · test: R2's tests run against the original's `LoginItemRegistering` · status: active [agent-inferred 2026-11-12]
- **A2 · Launch at login is on by default in the fork's non-App-Store builds, applied once at the first launch from `/Applications`, never again.** flip at: the owner prefers the original's default (off), which drops R2, R3 and the default part of R4 and R5 · test: R2's decision tests · status: active [agent-assumed 2026-11-12]
- **A3 · The App Store build keeps launch at login off by default.** why: Apple's App Review Guidelines (2.4.5) forbid starting at login without the user's consent · flip at: none expected · test: R3's App Store case · status: active [agent-inferred 2026-11-12]
- **A4 · The default applies only to a bundle directly in `/Applications`, and not when the other Meeting Transcriber copy is installed there.** why: keeps build folders and e2e copies out of the login items, and keeps two copies from both starting and both recording one meeting · flip at: a user who installs elsewhere asks for the default · test: R3's location and other-copy cases · status: active [agent-assumed 2026-11-12]
- **A5 · A failed register is not retried at later launches.** flip at: R5 or a user report shows a register that fails once and works later · test: R2's error case · status: active [agent-assumed 2026-11-12]
- **A6 · If R5 finds the item lost after an mt-update install, the agent reports instead of adding a re-register rule.** why: a re-register at launch can fight a user's off switch in System Settings, and the status macOS reports there is not measured · flip at: R5's check fails · test: R5's check · status: active [agent-assumed 2026-11-12]
- **A7 · The notice dates both times when they fall on different days, instead of naming the length.** why: the smaller change, one date format, no rounding rule for lengths · flip at: the owner prefers the length ("for 2 days") · test: R1's test · status: active [agent-assumed 2026-11-12]
- **A8 · "Start watching when the app opens" keeps its default (off).** why: the original and the fork both keep it off, and starting detection without a click is a separate choice · flip at: the owner wants both on by default · test: none, unchanged · status: active [agent-assumed 2026-11-12]
