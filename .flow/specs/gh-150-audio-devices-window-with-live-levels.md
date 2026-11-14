# Audio devices window with live levels

## Conversation Evidence

The fork is public, so the owner's turns are paraphrased, not quoted.

> owner (paraphrased, gh-148 conversation, 2026-10-14): asked for a level indicator per device, so the right microphone or output can be found when a track comes out silent.
> owner (selected, gh-148 D2, 2026-10-14): the Output entry and its switch come first; level meters per device go to a later build.
> owner (paraphrased, issue #150, 2026-10-14): when a track comes out silent, it is hard to tell which microphone or output device carries the sound; a live level indicator per device, for microphones and outputs, would show the right one to pick. Levels of devices that are not recorded need extra capture, so probably more permissions and a privacy indicator.
> owner (paraphrased, 2026-11-14): in the app's audio devices area, a new window with a detail view of the audio devices. For each device it also shows the current recording level as a graphic, so it is easy to see which device is in use right now and which one carries a signal.

## Goal & Context

<!-- Source: 40% [paraphrase] / 60% [inferred] -->

When a recording's track comes out silent, or a call sounds wrong, it is hard to tell which microphone or output the meeting app uses and which one carries sound. The menu bar's Audio Devices section names only the chosen microphone and the Mac's output (gh-148). After this spec, a window **Audio Devices**, opened from that section, lists every microphone and every output. Each row says whether the app records it, whether the meeting app uses it, whether any app is running audio on it right now, and whether it is the Mac's default. While a recording runs, the recorded microphone and the recorded meeting audio show their live level as a bar. Switching stays in the menu.

The first build stays within what the app captures already, plus read-only device status from Core Audio. Opening a device only to meter it would show the orange microphone indicator, would switch a Bluetooth headset to its call profile and, during a recording, can stall the app-audio capture (`docs/architecture/recording.md`, start order). Levels for devices the app does not record are therefore a later step the owner can ask for (A2).

## Architecture & Data Models

- **One new window, "Audio Devices"**, a window scene like All Recordings, opened by a new last item in the menu bar's Audio Devices section, under the Microphone and Output entries (A1). Choosing the item opens the window or brings it to the front. [inferred]
- **One pure value decides what the window shows**, in the way `MicrophoneMenuState` and `OutputMenuState` decide the menu entries: the rows of each group, every mark, every string, and whether a row shows a level bar. The window only renders it, so every arm is tested without the window. [inferred]
- **Its inputs are values the app already holds:** the microphone list and the default input name (the list the Microphone entry offers), the output list and the default output (the list the Output entry offers), the configured microphone and "No Microphone", the device the running recording captures, the meeting microphone probe's result (which input devices the tapped meeting app uses), whether a recording runs or is paused, and the two recorded levels in dBFS. Two readings are new: per device, Core Audio's "device is running somewhere" flag, and, during a recording, which output devices the tapped meeting app plays to (the output-scope counterpart of the meeting microphone probe). [inferred]
- **Levels come only from the running recording** (A2): the microphone track's level on the recorded microphone's row, and the app-audio track's level on its own "Meeting audio" row named after the recorded app (A3). The app-audio tap records the meeting app's sound whatever output it plays to, so that level belongs to the app, not to an output row. [inferred]
- **New readings run off the main thread**, one at a time, only while the window is open, because coreaudiod can stop answering (`docs/architecture/recording.md`, capture-restart bounding). [inferred]

## API Contracts

- The debug `/state` snapshot gains `audioDevicesWindow`: `{ "open": true, "rows": [ { "group": "microphone", "name": "USB Headset", "marks": ["meetingApp", "inUse"], "meetingApp": "Teams", "levelBar": false } ] }`. `group` is `microphone`, `output` or `meetingAudio`; `marks` holds any of `recording`, `meetingApp`, `inUse`, `default`, `notConnected`, `routingWarning`, `paused`, `unknown`; `meetingApp` is null unless `marks` holds `meetingApp`; `levelBar` says whether the row shows a level bar. Not part of the `/v1` automation API. [inferred]
- No new setting, and no change to `/v1`. [inferred]

## Edge Cases & Constraints

- **No recording running:** no level bars; one line says levels show while a recording runs. Marks other than the meeting app's still show. [inferred]
- **"No Microphone (app audio only)" on, or an app-only recording:** no microphone row is marked as recorded and no microphone bar shows; the Meeting audio row still does. [inferred]
- **Recording paused:** bars show no level, and the Meeting audio row says paused. [inferred]
- **A device with both input and output** (a USB headset) appears once in each group. [inferred]
- **The app's own capture counts as running:** the recorded microphone and the output the app-audio tap is built on report "running" because of this app. So the `inUse` mark, shown as "In use", says only that some app, this one included, runs audio on the device; no string claims "another app". [inferred]
- **A configured microphone that is not connected** is listed in the microphone group as not connected, as in the Microphone entry; the Mac's default output that the Mac does not offer (the Teams device) is listed with the menu's routing warning. [inferred]
- **A failed or late read** shows the mark `unknown` on that row, never "not running": "not in use" and "could not ask" must stay apart. A read that has not returned within two seconds leaves the window responsive and its rows `unknown`. [inferred]
- **Devices come and go:** the lists refresh while the window is open when a device is added or removed or a default changes, as the menu entries do. [inferred]
- **Privacy:** the window shows device names and the meeting app's name, never the meeting title and never a device UID (a USB UID carries the serial number). Nothing new is logged. Others may see the window during a screen share. [inferred]
- **Both build variants** get the window; a read the App Store sandbox refuses shows as `unknown`. [inferred]

## Acceptance Criteria

- **R1:** The menu bar's Audio Devices section ends with an item that opens the Audio Devices window, or brings it to the front when it is open; the item's wording and the window's layout and wording are the accepted mockup's. Errors: the item shows exactly when the section shows; no second window opens on a second choice. [inferred]
- **R2:** The window lists every microphone the Microphone entry offers and every output the Output entry offers, in two groups and in the menus' order, each by its name, and refreshes while open when a device is added or removed or a default changes. Errors: an empty group shows one "None found" line; a configured microphone that is not connected is listed as not connected; a device with both input and output appears in both groups. [paraphrase]
- **R3:** Each row shows its marks: `recording` on the microphone the running recording captures; `meetingApp` with the app's name on a microphone or an output the tapped meeting app uses during a recording; `inUse` while Core Audio reports the device running for any process; `default` on the Mac's default input and default output. When the Microphone entry shows its hint about the meeting app's microphone, the window shows the same hint. Errors: a failed or late read shows `unknown` on that row, never "not running"; outside a recording no row carries `recording` or `meetingApp`. [inferred]
- **R4:** While a recording runs and is not paused, the recorded microphone's row and a "Meeting audio" row named after the recorded app show a live level bar from the recording's microphone and app-audio tracks, updated at least ten times a second while the window is visible. Errors: no recording → no bars and one line that says levels show while recording; microphone off or an app-only recording → no microphone bar; paused → empty bars and the Meeting audio row says paused; a track that stops delivering → its bar falls to empty within one second. [inferred]
- **R5:** Opening, showing and closing the window opens no audio input, installs no audio tap and starts no capture, with or without a recording: the window adds no orange microphone indicator and changes no Bluetooth headset's profile. Errors: no error surface beyond R3's `unknown`. [inferred]
- **R6:** The new Core Audio readings run off the main thread, at most one at a time, only while the window is open, and stop when it closes; the window stays responsive while a reading hangs. Errors: a reading that has not returned within two seconds → the rows it would answer show `unknown` until a later reading returns. [inferred]
- **R7:** The debug `/state` snapshot carries `audioDevicesWindow` as in API Contracts, and `docs/architecture-macos.md` lists the window and where it gets each mark and level. Errors: window closed → `open: false` and `rows: []`. [inferred]

## Boundaries

- No levels for devices the app does not record: that needs opening each microphone or a tap per output, with the orange indicator, the grants and the Bluetooth profile switch (A2). [paraphrase]
- No switching devices in the window; the menu's Microphone and Output entries stay the place to switch (A5). [inferred]
- No change to what or how the app records, and no new setting. [inferred]
- No change to the menu's Microphone and Output entries beyond the new item. [inferred]

## Decision Context

- **D1 · A window opened from the app's audio devices area lists the audio devices and shows, per device, its current recording level as a graphic, so it is easy to see which device is in use right now and which one carries a signal.** why: the owner's wish of 2026-11-14 (paraphrased), continuing issue #150, which gh-148 deferred (its D2: level meters per device in a later build) · status: active [owner-stated 2026-11-14]
- **A1 · The window opens from a new last item in the menu bar's Audio Devices section.** flip at: the owner's answer · test: R1's menu wiring test · alternatives: B a button in Settings → Audio; C both · status: active [agent-assumed 2026-11-14]
- **A2 · Levels only for the two tracks a running recording captures; every other row shows status only, and the window opens no device.** flip at: the owner's answer · test: R4's state tests and R5's no-capture test · alternatives: B every microphone metered while the window is open (orange indicator, Bluetooth headsets in call quality, can stall a running recording's app audio); C as A plus a Test button per microphone outside a recording, as a follow-up spec · status: active [agent-assumed 2026-11-14]
- **A3 · Microphones and outputs are both listed, and the meeting audio level sits on its own "Meeting audio" row named after the recorded app, not on an output row.** flip at: the owner's answer · test: R2's and R4's state tests · alternatives: B microphones only; C a level per output from a tap on each output device · status: active [agent-assumed 2026-11-14]
- **A4 · "In use" shows as separate marks: recording (this app records it), the meeting app's name (during a recording), in use (Core Audio reports it running for any app, this one included), default.** flip at: the owner's answer · test: R3's state tests · alternatives: B one dot for any use, without saying who; C every app's name on every device, outside a recording too · status: active [agent-assumed 2026-11-14]
- **A5 · The window is read-only; switching stays in the menu.** flip at: the owner's answer · test: R1's view test finds no control in a device row · alternatives: B a Use button per row that does what the menu's choice does (an output choice changes the Mac's output system-wide) · status: active [agent-assumed 2026-11-14]
- **A6 · An ordinary window like All Recordings, not one that floats above other apps.** flip at: the window scene · test: R1's window test · alternatives: B a floating panel while a recording runs · status: active [agent-assumed 2026-11-14]
- **A7 · The running flag is read per device while the window is open, refreshed about once a second or on Core Audio's change notice, and the meeting app's outputs on the five-second cadence of the meeting microphone probe.** flip at: the device status reader · test: R6's reader tests · status: active [agent-assumed 2026-11-14]

Mockup gate: plan and work wait until the owner has accepted the mockup of the device window (layout and wording) on a design canvas.
