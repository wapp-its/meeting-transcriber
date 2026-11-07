---
title: A confirmation text read the record while its size came from the disk
date: "2026-11-06"
track: bug
category: ui
module: TrashConfirmationText
tags: [confirmation-text, stale-record, regenerate-notes]
problem_type: ui
symptoms: "A Trash confirmation counted and named files already removed by hand, and missed or overstated that Regenerate Notes keeps working"
root_cause: The text read the record's file list where the row's disk answers were the truth
resolution_type: fix
---

## Problem
A confirmation before a Trash action took the number and names of the files from the meeting's record and the size from the disk. A file removed by hand stays in the record until an action finds it gone, so with two of three tracks removed the dialog said "3 audio files (48 MB)" and listed all three names. The same text promised "Regenerate Notes keeps working" by whether a transcript file was listed, which was wrong in both directions: notes that hold the transcript regenerate fine with no transcript file, and a blank transcript file with nothing in the notes does not.

## What Didn't Work
Treating the mix as acceptable because the action itself finds the gone files and handles them correctly. The action was right, but the dialog that asks the user to agree to it described something else. A filter that dropped all audio only when none was left covered the all-gone case and not the partial one.

## Solution
`RecordingAudioLine.AudioOnDisk` carries `gonePaths`, the listed paths the disk answered gone, and `TrashConfirmationText` leaves those out of the number, the names and the words for what stays or goes. `moveAudio` takes the regenerator's own `TranscriptSource` as a required input, so the promise cannot differ from what the row's Regenerate item offers.

## Prevention
When one sentence mixes a value from a record with a value from the disk, test the case where they disagree. When a text promises what another feature can do, feed it that feature's own answer instead of deriving a guess from a file list.
