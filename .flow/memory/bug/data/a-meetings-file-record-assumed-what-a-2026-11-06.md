---
title: A meeting's file record assumed what a write did instead of asking the disk
date: "2026-11-06"
track: bug
category: data
module: app/MeetingTranscriber/Sources/MeetingFileStore.swift
tags: [meeting-file-record, naming, output-folder, reachability]
problem_type: data
symptoms: A failed naming save listed a link's target as owned; a write to another folder dropped a file still on disk
root_cause: "A hook inferred a write from a file at the path, and listing replaced an entry by role without probing the old path"
resolution_type: fix
---

## Problem
A meeting's file record drives later deletions, so it must name exactly the files the disk holds for that meeting. Two hooks recorded what they assumed instead of what happened. A naming save reported its file from a `defer` whenever something sat at the path, so after a failed write a symbolic link there made the record list the link's target as owned. And listing a file replaced whatever its role listed, so a run writing to another output folder dropped the first folder's file from the record, also when that folder was only unreachable, which leaves the file on disk out of reach of a deletion.

## What Didn't Work
The `defer` was chosen because a refused chmod throws after the atomic write already replaced the file, so "report on success" alone would miss a rewrite. Checking that a file exists at the path does not separate "this write landed" from "something else is here". Task-level tests passed throughout, because each wrote to one folder and never failed a write.

## Solution
`SpeakerNamingStore.save` hands the path to a closure between the write and the chmod, the same order the transcript rewrites use. `MeetingFileRecord.list` replaces only the entry of its own path, and `MeetingFileStore.list` asks `MeetingFilePresence` outside the lock which earlier files of the role stay: one leaves the record only when the disk answers that it is gone. A role can therefore list several files.

## Prevention
A record hook states a fact about the disk, so it reports right after the operation that caused it and never infers it from a later look at the path. Whatever replaces an entry asks the same question as whatever marks one gone: "gone" comes from the presence probe, never from a newer write. For any new hook, test a failed write with something already at the path, and a second write into another folder with the first folder unplugged.
