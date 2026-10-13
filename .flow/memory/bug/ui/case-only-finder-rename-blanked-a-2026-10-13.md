---
title: Case-only Finder rename blanked a picker keyed by a stored file name
date: "2026-10-13"
track: bug
category: ui
module: app/MeetingTranscriber/Sources/Settings/ProtocolTemplatesSettingsView.swift
tags: [swiftui-picker, case-insensitive-filesystem, protocol-templates]
problem_type: ui
symptoms: Default template picker blank and stale default kept after renaming Board.md to board.md
root_cause: Stored name resolved on the case-insensitive volume but matched no listed picker tag; delete compared exactly
resolution_type: fix
---

## Problem
The Default template picker in Settings → Output used the stored template name as its selection, and its tags came from the folder listing. When the default `Board.md` was renamed to `board.md` in Finder, the stored "Board" still resolved on the default case-insensitive APFS volume (so `ProtocolTemplateStore.effectiveDefault` kept returning `.file("Board")`), but no picker tag was "Board", so the picker went blank. Deleting "board" compared names exactly, so the stale default survived and came back if the file reappeared. The impl-review caught this.

## What Didn't Work
Comparing the stored name with the listed names exactly (`settings.defaultProtocolTemplate == .file(name: name)`), and treating "the file resolves" as "the picker can show it".

## Solution
`ProtocolTemplatesModel.defaultSelection` (app/MeetingTranscriber/Sources/Settings/ProtocolTemplatesSettingsView.swift) returns the effective default spelled as the folder lists it: an exact match first, then a case-insensitive one (`listed(_:)`). `confirmDelete` reads that selection before the file goes, to decide whether it is deleting the default. On a case-sensitive volume holding both files, the exact match wins, so only the right file resets the default. Reading the selection never rewrites the setting. Test: `ProtocolTemplatesSettingsTests.testACaseOnlyRenameOfTheDefaultStaysSelectedAndDeletable`.

## Prevention
Whenever a SwiftUI Picker's selection is a stored name and its tags come from a directory listing, map the stored value onto the listed spelling before using it as the selection. Test a case-only rename on the temp directory, which is case-insensitive like the default macOS volume, and skip the test on a case-sensitive volume.
