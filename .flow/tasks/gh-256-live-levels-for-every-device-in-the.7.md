---
satisfies: [R10, R13]
---
# gh-256-live-levels-for-every-device-in-the.7 Live checks and the measured performance budget

## Description
The live checks in the running dev app with the debug RPC on (Validation steps 6 and 7), the performance budget measured as A9 says, and the numbers in `docs/architecture-macos.md` (R10, R13). A missed budget stops the build here and reports the numbers rather than shipping (R10).

**Size:** S
**Files:** `docs/architecture-macos.md`
**Touches:** [docs/architecture-macos.md]

### Approach
1. **Where it runs:** the installed dev app with this branch's build. Per the fork rules ("Trying a change in the installed app"), a branch tried before its merge gets its own line in `branches.txt` on branch `tools` and joins the "Long-lived branches: no deletion" ruleset, then `mt-update` installs it (it waits until the app is idle; never quit the app any other way). If the run cannot arrange that, stop with `NEEDS_HUMAN` naming this step: R10 forbids merging without the numbers.
2. **Step 6:** `/action/openAudioDevices`, then `/state.audioDevicesWindow`: `meters.state` running, `openInputs` and `openOutputs` equal to the listed devices, `selfRunningInput` true; play the meeting simulator's audio and see its output row light; close and see every count at zero within one second. Start the meeting simulator as a watched call: `meters.state` paused with `pauseReason: "call"` and `selfRunningInput` false before its recording starts; during the recording only the recorded rows show bars. Start a manual recording with the meters running: its start waits for the close and both tracks deliver.
3. **Budget** (A9): with every device the build Mac has metered (count recorded), 30 s of per-second `ps -o %cpu,rss` samples of the app and of coreaudiod with the window open, against 30 s with it closed; the window's state changes per second (from `/state` polling or the reader's change count); resident memory after 20 open and close cycles; no meter open one second after a close. Record the numbers and the device count in `docs/architecture-macos.md` beside the meters paragraph.
4. **Step 7:** with a Bluetooth headset connected, the step 6 manual start ten times with the headset as output, each with a delivering app track; without one, list it as unverified in the done summary for the owner to run.
5. No recording or transcript content enters the logs or the summary; only counts, states and numbers.

### Investigation targets
**Required** (read before coding):
- `.claude/rules/wapp-fork.md` — "Trying a change in the installed app", `branches.txt`, the ruleset
- `docs/architecture/debug-rpc.md` — `/state`, actions, auth
- `.claude/skills/e2e-architecture/` — the meeting simulator and live lanes

**Optional** (reference as needed):
- `tools/mt-cli/` — RPC client
- `tools/meeting-simulator/` — simulated call audio

## Acceptance
- [ ] Validation step 6 run in the dev app with this build: each `/state` observation recorded in the done summary, or the step reported as blocked from verification with the reason.
- [ ] A9's budget measured and recorded in `docs/architecture-macos.md` with the device count; every limit met, or the build stopped with the numbers reported.
- [ ] Validation step 7 run with a Bluetooth headset, or listed as unverified for the owner.


## Done summary
TBD

## Evidence
- Commits:
- Tests:
- PRs:
