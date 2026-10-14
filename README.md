# mt-update

Baut Meeting Transcriber aus dem neuesten Stand von
[pasrom/meeting-transcriber](https://github.com/pasrom/meeting-transcriber)
plus den Branches in `branches.txt` und installiert die App nach
`/Applications/MeetingTranscriber-Dev.app`.

Die vollständige Anleitung für neue Nutzer (Voraussetzungen, erste Einrichtung)
steht auf der [Startseite des Forks](https://github.com/wapp-its/meeting-transcriber).

Voraussetzung: Xcode 26 oder neuer.

Einmal einrichten:

```
mkdir -p ~/.local/bin && curl -fsSL https://raw.githubusercontent.com/wapp-its/meeting-transcriber/tools/mt-update.sh -o ~/.local/bin/mt-update && chmod +x ~/.local/bin/mt-update
```

Danach, in jeder Shell (`~/.local/bin` muss dafür nicht im `PATH` sein):

- `~/.local/bin/mt-update` — neuesten Stand bauen, installieren, starten
- `~/.local/bin/mt-update --check` — nur anzeigen, ob es Neues gibt

Liegt `~/.local/bin` im `PATH`, reicht `mt-update`.

Schlägt das Mischen oder Bauen fehl, bleibt die installierte App unverändert.
Läuft gerade eine Aufnahme oder ein Transkriptions-Job, wartet `mt-update` nach
dem Bauen, bis die App frei ist (höchstens 3 h), und ersetzt sie erst dann.
Offene Sprecher-Benennungen blockieren nicht, sie erscheinen nach dem Neustart
wieder. `MT_NO_WAIT=1 mt-update` bricht stattdessen ab.
Das Skript aktualisiert sich bei jedem Lauf selbst von diesem Branch, sofern die
Datei `mt-update` heißt (die Kopie `mt-update.sh` im Checkout nie).

## Einreichen ans Original: `submit.sh`

Baut `submit/<name>` frisch auf dem neuesten Stand des Originals, mit genau den
Code-Commits eines Feature-Branches (ohne die flow-next-Buchhaltung `.flow/`).
Bricht ab, wenn der Branch `.claude/rules/`, `CLAUDE.md` oder `AGENTS.md` ändert
oder Commit-Nachrichten auf Issues oder Specs des Forks verweisen.

In einem Checkout des Forks (mit Remote `upstream` = Original):

- `submit.sh feat/<name>` — nur lokal bauen und prüfen
- `submit.sh feat/<name> --go --body-file pr.md` — in den Fork pushen und den PR
  im Original als Entwurf öffnen (bzw. einen offenen aktualisieren); nur nach
  Freigabe

`mt-update` erkennt einen übernommenen PR auch dann, wenn er über `submit/<name>`
eingereicht wurde, und lässt den Branch dann weg.
