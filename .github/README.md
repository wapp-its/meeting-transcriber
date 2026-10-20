# Meeting Transcriber (wapp-its build)

This repository is a fork of
[pasrom/meeting-transcriber](https://github.com/pasrom/meeting-transcriber), an app
for macOS that records your meetings and transcribes them on your Mac. The fork adds
features that the original does not have. This page tells you how to install the
fork's build and how to keep it up to date.

For everything else, read the
[original README](https://github.com/wapp-its/meeting-transcriber/blob/wapp/main/README.md).
It explains how the app works, its settings and how to fix common problems.

There is no ready-made download for this build. A script, `mt-update`, builds the
app on your Mac from the newest code and installs it. You run the same script
again to update.

## What this build adds

- It asks before it records. Each detected meeting shows a question ("Record
  Teams meeting?") with Record, Ignore and "Never for this app". A reminder says
  that everyone in the meeting must agree to the recording.
- It asks before it stops. It asks before a recording stops automatically, and
  after a long silence. You can also stop a detected meeting yourself.
- The menu bar is clearer. The icon shows whether the app is watching for meetings
  and whether a question waits for you. The menu shows the microphone in use and
  warns when the meeting app uses a different one.
- An All Recordings window (Cmd-T) lists all your transcriptions and searches them.
- Your own voice is about as loud as the others in the saved recording. Before,
  it was often much quieter.
- You can use your own Whisper model from Hugging Face or from a folder on your
  Mac. A Hugging Face token in Settings gives access to private models.
- A whole team can share one vocabulary list, loaded from a URL.
- Speaker separation with NVIDIA Nemotron 3 handles up to 8 speakers, also when
  they talk at the same time.
- Codex CLI or any command-line tool can write the protocol (the meeting summary),
  in addition to Claude CLI and local model servers.
- All permissions are in one place: Settings → Advanced → Permissions.

The full list is in the
[merged pull requests](https://github.com/wapp-its/meeting-transcriber/pulls?q=is%3Apr+is%3Amerged+base%3Awapp%2Fmain).

## Before you start

You need:

- A Mac with macOS 14.2 or later.
- Xcode 26 or later, from the App Store. The Command Line Tools alone are not
  enough.
- About 5 GB of free disk space for the build and the speech models, in
  addition to the space for Xcode.
- Optional, but strongly recommended: an Apple Development certificate. A free
  Apple ID is enough. Without it, macOS asks you again for the microphone and screen
  recording permissions after each update.

To prepare Xcode:

1. Install Xcode from the App Store.
2. Open Xcode once and let it install its components.
3. Run this command in Terminal. It makes sure that the build uses Xcode and not
   only the Command Line Tools:

   ```
   sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer
   ```

To get the certificate:

1. In Xcode, open **Settings → Accounts**.
2. Click **+**, select **Apple ID** and sign in.
3. Select your team (for a free Apple ID, "Personal Team") and click
   **Manage Certificates**.
4. Click **+** and select **Apple Development**.

## Install

1. Open Terminal.
2. Download the `mt-update` script:

   ```
   mkdir -p ~/.local/bin && curl -fsSL https://raw.githubusercontent.com/wapp-its/meeting-transcriber/tools/mt-update.sh -o ~/.local/bin/mt-update && chmod +x ~/.local/bin/mt-update
   ```

3. Run it:

   ```
   ~/.local/bin/mt-update
   ```

The first run takes about 5 to 10 minutes. The script downloads the code into
`~/Library/Application Support/mt-update`, builds the app, installs it as
`/Applications/MeetingTranscriber-Dev.app` and starts it. The app lives in the menu
bar. It has no Dock icon. The script writes its messages in German.

These commands work in every shell (zsh, bash, fish). If `~/.local/bin` is in your
`PATH`, you can type `mt-update` instead of `~/.local/bin/mt-update`.

## Set up the app

Click the menu bar icon and open **Settings**.

1. **Permissions** (Advanced → Permissions): allow **Microphone**. Allow
   **Screen Recording** too, or allow audio recording when macOS asks for it.
   Without one of these two, the other participants are silent in your recordings.
   Screen Recording takes effect only after you quit and reopen the app.
2. **Transcription engine** (Transcription): select **Parakeet** for 25 European
   languages (fast, small download) or **WhisperKit** for 99 languages (about 1 GB).
   The app downloads the model the first time it needs it.
3. **Protocol** (Output → Protocol Generation): select how the app writes the
   meeting summary, and in which language. You can select Claude CLI or Codex CLI
   (installed and signed in), a command-line tool of your own, a local model server
   such as LM Studio or Ollama, or None (transcript only).
4. **Output folder** (Output → Output Folder): select where transcripts and
   protocols go.
5. **Meeting apps** (General → Apps to Watch): select the apps whose meetings the
   app should detect. Then select **Start Watching for Meetings** in the menu.

Optional: to import MKV or WebM files, install ffmpeg with `brew install ffmpeg`.

**Where your data goes:** recording, transcription and speaker separation run on
your Mac. Only the protocol can leave it: Claude CLI and Codex CLI send the
transcript to Anthropic or OpenAI. A local model server keeps it on your Mac.

## Update

To see if a newer build is available:

```
~/.local/bin/mt-update --check
```

To build and install it:

```
~/.local/bin/mt-update
```

- If a recording or a transcription runs, the script waits until it is finished
  (at most 3 hours). Then it replaces the app and starts it again.
- If the build fails, your installed app stays as it is.
- The script updates itself each time it runs.

**Ignore "Update available" in the app.** The app's own update check looks at the
releases of the original project. Such a release installs a second, separate app
without the features of this build. To turn the check off, clear
**Settings → About → Check for Updates**. An update button in the app that uses
`mt-update` is planned
([issue #8](https://github.com/wapp-its/meeting-transcriber/issues/8)).

## Next to the original app

You can keep the original app installed, but run only one of the two at a time.
Both keep voice profiles, recordings and jobs in
`~/Library/Application Support/MeetingTranscriber`. Their settings are separate.

## Uninstall

1. Quit the app from its menu.
2. Delete these files and folders:
   - `/Applications/MeetingTranscriber-Dev.app`
   - `~/.local/bin/mt-update`
   - `~/Library/Application Support/mt-update` (the build, about 1.5 GB)
3. To remove your data too, delete
   `~/Library/Application Support/MeetingTranscriber` (voice profiles, recordings).
   The speech models are in `~/Documents/huggingface` and
   `~/Library/Application Support/FluidAudio`.

## Problems

Open an issue in
[this repository](https://github.com/wapp-its/meeting-transcriber/issues). If the
update failed, add the output of `mt-update` and the last lines of
`~/Library/Application Support/mt-update/build.log`.
