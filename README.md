# mt-update

Baut Meeting Transcriber aus dem neuesten Stand von
[pasrom/meeting-transcriber](https://github.com/pasrom/meeting-transcriber)
plus den Branches in `branches.txt` und installiert die App nach
`/Applications/MeetingTranscriber-Dev.app`.

Voraussetzung: Xcode 26 oder neuer.

Einmal einrichten:

```
mkdir -p ~/.local/bin && curl -fsSL https://raw.githubusercontent.com/wapp-its/meeting-transcriber/tools/mt-update.sh -o ~/.local/bin/mt-update && chmod +x ~/.local/bin/mt-update
```

Danach:

- `mt-update` — neuesten Stand bauen, installieren, starten
- `mt-update --check` — nur anzeigen, ob es Neues gibt

Schlägt das Mischen oder Bauen fehl, bleibt die installierte App unverändert.
Das Skript aktualisiert sich bei jedem Lauf selbst von diesem Branch.
