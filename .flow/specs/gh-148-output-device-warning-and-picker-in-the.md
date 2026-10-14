# Output device warning and picker in the menu

## Conversation Evidence

> user (turn 1, paraphrased): asked why a Teams meeting they had just recorded came out empty, with not even the app sound audible and no warning shown, and whether switching audio devices in the Teams meeting had caused it. [paraphrase]
> user (turn 2, selected): "A — Start warning (Recommended)"
> user (turn 3, paraphrased): wished the menu showed the output device being recorded next to the microphone and allowed changing it; asked for the silence message to stay on screen, for a level indicator per device to find the right one, and whether switching during a recording still records into the same file. [paraphrase]
> user (turn 3, selected): "A — Warning + output picker"
> user (turn 4, paraphrased): the current banner can stay, as long as the menu-bar icon shows that something is wrong. [paraphrase]

## Goal & Context

A meeting was recorded with an empty app track, and the user found out only after the meeting. [paraphrase] The diagnosis showed that Teams had set the Mac's default output to its own virtual device "Microsoft Teams Audio" (device UID `MSLoopbackDriverDevice_UID`) a few minutes before the meeting, while it kept playing the call through another device. With that routing the app-audio tap delivers digital silence for the whole recording. [inferred] The same routing is reported upstream as pasrom/meeting-transcriber#712, which has no merged fix. [inferred]

The user should learn about this routing at the moment it can still be fixed, which is the start of the recording, and should be able to fix it from the app's menu instead of hunting for the setting. [paraphrase] The fix is to switch the Mac's sound output to the real device; the app-audio capture follows the Mac's default output, and a change of it during a recording already rebuilds the capture and keeps writing into the same file, with the gap filled by silence. [inferred]

## Architecture & Data Models

- One pure decision function answers "should the user be warned about the output routing now?" from: the default output device's UID, whether the recording captures an app track, and whether this recording already warned for the current routing. It owns no state and touches no Core Audio API, so it is unit-testable. [inferred]
- The recording side already reads the default output device when it creates the app-audio tap, and already observes default-output changes during a recording (it rebuilds the tap on them). The warning hooks into those two existing points rather than adding a new poll or listener. [inferred]
- The once-per-routing memory belongs to the recording in progress and is reset when a recording starts. [inferred]
- The warning is posted through the existing notification path and logged unconditionally in the existing app-audio diagnostics. [inferred]
- While the routing warning holds, the menu-bar icon shows it with the existing app-channel problem signal (the red tint of the waveform's bottom half that a silent app channel already uses), from the moment the routing is seen and not after a silence window. The flag that drives it belongs to the recording in progress and clears when the routing changes away from the Teams device or the recording stops. [inferred]
- The menu's Output entry is described by one pure value, built the same way as the existing Microphone entry's value: title, items, the checked item and an optional hint line, all strings decided there, so the dropdown itself stays manual QA and every arm is unit-tested. Its inputs are the current default output device and the list of output devices. [inferred]
- Choosing an item sets the Mac's default output device (system-wide, the same effect as choosing it in Control Center). The app stores no output choice of its own: the Mac's setting is the single owner of that state. [inferred]

## API Contracts

- Notification, posted while recording (shape; wording may be polished, the facts may not change): [inferred]
  - title: `Meeting Audio May Not Be Recorded`
  - body: names "Microsoft Teams Audio" as the Mac's current sound output, says the meeting's audio may not reach the recording, and tells the user to pick their speakers or headset under Output in the app's menu (or in Control Center).
  - urgency: the app's level for a failure in progress (the same level the capture-fault alerts use).
- Diagnostic log line, not behind the verbose toggle, on each warning: names the trigger (`start` or `output change`) and the device UID. [inferred]
- Menu, directly below the Microphone entry: [inferred]
  - an `Output: <device name>` entry that opens a submenu listing the Mac's output devices, with a checkmark on the current default output.
  - when the current default output is the Teams loopback device, the entry's title carries a warning mark and the submenu shows a disabled hint line: the meeting audio may not be recorded, pick your speakers or headset.
- Menu-bar icon: while a recording with an app track runs and the default output is the Teams loopback device, the waveform's bottom half is tinted red, the same signal a silent app channel shows; it follows the existing per-channel indicator setting. [inferred]
- No other new settings, endpoints or `/state` fields. [inferred]

## Edge Cases & Constraints

- Matching is on the device UID `MSLoopbackDriverDevice_UID`, never on the display name: the name is localisable and user-visible, the UID is the driver's identity. [inferred]
- A virtual default output in general is not a fault (#712 measured working recordings into other virtual devices), so no other virtual device triggers the warning or the warning mark. [inferred]
- A recording without an app track (microphone-only) never warns: the routing cannot affect it. [inferred]
- The routing check never blocks or delays the start of the recording, and a failed device read (UID unavailable) produces no warning and no error. [inferred]
- Record-only mode warns the same way: it still captures the app track. [inferred]
- The Output submenu lists only devices the Mac offers as sound outputs: the app's own private capture aggregates and other private aggregate devices never appear. [inferred]
- The Output entry reflects changes made elsewhere (Control Center, Teams, a device plugged in or removed) the next time the menu opens, without an app restart. [inferred]

## Acceptance Criteria

- **R1:** When a recording with an app track starts while the Mac's default output device has UID `MSLoopbackDriverDevice_UID`, the user gets the notification described in API Contracts within the first seconds of the recording. Errors: default output UID unreadable → no notification, recording starts normally; any other default output (including other virtual devices) → no notification. [paraphrase]
- **R2:** When the default output changes to the Teams loopback device during a recording with an app track, the user gets the same notification once for that change. Errors: a change between two non-Teams devices → no notification; a change away from the Teams device and back again → one more notification for the new change. [inferred]
- **R3:** A recording warns at most once for an unchanged routing: tap rebuilds, retries or other restarts while the default output stays the Teams loopback device post no further notifications. No error surface beyond R1 and R2. [inferred]
- **R4:** A recording without an app track never posts this notification, whatever the default output is. No error surface beyond this. [inferred]
- **R5:** Each warning writes one unconditional diagnostic log line naming the trigger and the device UID. No error surface beyond R1. [inferred]
- **R6:** The menu shows an `Output: <device name>` entry below the Microphone entry, naming the Mac's current default output, with a submenu of the Mac's output devices and a checkmark on the current one. Errors: default output unreadable → the entry reads `Output: Unknown` with no checkmark and the submenu still lists the devices; no output devices found → the entry is one disabled line. [paraphrase]
- **R7:** Choosing a device in the Output submenu makes it the Mac's default output; during a recording the app track then continues in the same file through the existing output-change path. Errors: the system refuses the change → the default output stays as it was, the entry keeps showing the actual current device, and one unconditional diagnostic line records the refusal with its status. [paraphrase]
- **R8:** While the Mac's default output is the Teams loopback device, the Output entry's title carries a warning mark and its submenu shows the hint line from API Contracts; with any other output neither appears. No error surface beyond R6. [inferred]
- **R9:** While a recording with an app track runs and the Mac's default output is the Teams loopback device, the menu-bar icon shows the app-channel problem signal; it clears once the default output changes to another device or the recording stops. Errors: per-channel indicator turned off in Settings → no tint, notification and menu entry unchanged; microphone-only recording → no tint. [paraphrase]

## Boundaries

- No automatic fix: the app never changes the Mac's default output on its own and does not re-anchor the tap on another device (that is option B, not chosen); the output changes only when the user picks it in the menu. [paraphrase]
- No live level indicators per device in the menu: filed as a separate follow-up. [paraphrase]
- No change to how long notifications stay on screen: that is the user's macOS notification setting for the app. [paraphrase]
- No warning while the app is only watching and not recording. [inferred]
- No change to the existing "Recording Appears Silent", "Capture Channel Silent" or silence-question notifications. [inferred]
- No new setting to turn the warning off. [inferred]

## Decision Context

- **D1 · Warn at recording start instead of fixing the capture automatically or waiting for upstream.** why: cheap, usable within about a day, fits exactly the observed case; an automatic fix needs a live Teams test first and upstream has no date · alternatives: B automatic re-anchoring, C wait for pasrom/meeting-transcriber#712 · status: active [owner-ratified 2026-10-14]
- **D2 · Add the Output entry with a switch to the menu in the same build; level meters per device go to a later build.** why: one place to notice and fix the routing, without the costly capture work level meters need · alternatives: warning only, everything including level meters · status: active [owner-ratified 2026-10-14]
- **A1 · Match only the Teams loopback UID, not every virtual output device.** flip at: the routing decision function · test: unit test that another virtual device UID does not warn · status: active [agent-inferred 2026-10-14]
- **A2 · Also warn when the routing changes to the Teams device mid-recording.** flip at: the output-change hook · test: unit test for the change transition · status: active [agent-inferred 2026-10-14]
- **A3 · The warning reaches the user as a notification, the Output entry's warning mark and the menu-bar icon; no /state field.** flip at: the warning's post site and the Output entry's value · test: wiring test that the notifier receives the post; unit test of the Output entry value · status: active [agent-assumed 2026-10-14]
- **D3 · Keep the current temporary banner, provided the menu-bar icon shows that something is wrong.** why: the icon stays visible for the whole recording, a banner does not · status: active [owner-stated 2026-10-14]
- **A5 · The icon reuses the red bottom-half tint of a silent app channel instead of a new badge.** flip at: the icon overlay inputs · test: unit test of the overlay flag for the routing state · status: active [agent-assumed 2026-10-14]
- **A4 · The Output switch changes the Mac's default output system-wide instead of an app-only capture device.** flip at: the Output entry's selection handler · test: unit test that a choice is forwarded to the default-output setter · status: active [agent-inferred 2026-10-14]
