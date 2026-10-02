#!/usr/bin/env bash
# mt-update — Meeting Transcriber mit unseren Erweiterungen bauen und installieren.
#
# Nimmt den neuesten Stand des Originals (pasrom/meeting-transcriber, main),
# mischt unsere eigenen Branches aus dem Fork dazu, baut die App lokal und
# ersetzt sie in /Applications. Welche Branches das sind, steht in
# branches.txt auf dem Branch `tools` des Forks. Branches, deren Pull Request
# im Original schon übernommen wurde, fallen automatisch weg.
#
# Schlägt das Mischen oder Bauen fehl, bleibt die installierte App unverändert.
# Läuft gerade eine Aufnahme oder ein Transkriptions-Job, wartet das Skript nach
# dem Bauen, bis die App frei ist, und ersetzt sie erst dann.
#
# Aufruf:  mt-update            bauen + (wenn frei) installieren + starten
#          mt-update --check    nur zeigen, was sich seit dem letzten Build geändert hat
#
# Anpassbar per Umgebung: MT_DIR (Checkout), MT_APP_DIR (Zielordner),
# MT_NO_LAUNCH=1 (App danach nicht starten), MT_BRANCHES (Liste statt branches.txt),
# MT_NO_WAIT=1 (nicht warten, sondern abbrechen, wenn die App beschäftigt ist),
# MT_WAIT_MAX (höchste Wartezeit in Sekunden, Standard 3 h),
# MT_DATA_DIR (Datenordner der App, für Tests).

set -euo pipefail

FORK_URL="https://github.com/wapp-its/meeting-transcriber.git"
UPSTREAM_URL="https://github.com/pasrom/meeting-transcriber.git"
UPSTREAM_API="https://api.github.com/repos/pasrom/meeting-transcriber"
FORK_OWNER="wapp-its"
TOOLS_RAW="https://raw.githubusercontent.com/wapp-its/meeting-transcriber/tools/mt-update.sh"

MT_DIR="${MT_DIR:-$HOME/Library/Application Support/mt-update/meeting-transcriber}"
MT_APP_DIR="${MT_APP_DIR:-/Applications}"
APP_NAME="MeetingTranscriber-Dev.app"
BUNDLE_ID="app.meetingtranscriber.dev"
STAMP="$MT_DIR/../last-build.txt"
MT_DATA_DIR="${MT_DATA_DIR:-$HOME/Library/Application Support/MeetingTranscriber}"
MT_WAIT_MAX="${MT_WAIT_MAX:-10800}"

CHECK_ONLY=false
[ "${1:-}" = "--check" ] && CHECK_ONLY=true

say() { printf '\033[1m%s\033[0m\n' "$*"; }
fail() { printf '\033[31m✗ %s\033[0m\n' "$1" >&2; exit "${2:-1}"; }

# --- 0. Sich selbst aktuell halten --------------------------------------------
self="$(command -v mt-update 2>/dev/null || true)"
if [ -n "$self" ] && [ -w "$self" ] && [ -z "${MT_NO_SELF_UPDATE:-}" ]; then
    tmp="$(mktemp)"
    if curl -fsSL "$TOOLS_RAW" -o "$tmp" 2>/dev/null && ! cmp -s "$tmp" "$self"; then
        install -m 755 "$tmp" "$self"
        rm -f "$tmp"
        say "mt-update wurde aktualisiert, starte neu …"
        MT_NO_SELF_UPDATE=1 exec "$self" "$@"
    fi
    rm -f "$tmp"
fi

# --- 1. Voraussetzungen --------------------------------------------------------
command -v git >/dev/null || fail "git fehlt"
xcode="$(xcodebuild -version 2>/dev/null | awk 'NR==1 {print $2}')" || true
[ -n "$xcode" ] || fail "Xcode fehlt (xcodebuild nicht gefunden)"
[ "${xcode%%.*}" -ge 26 ] || fail "Xcode $xcode ist zu alt, gebraucht wird 26 oder neuer"
if ! security find-identity -v -p codesigning 2>/dev/null | grep -q '[0-9]) '; then
    say "Hinweis: kein Signaturzertifikat gefunden. macOS fragt dann nach jedem Update"
    say "neu nach Mikrofon-/Bildschirmfreigabe. Abhilfe: Xcode → Settings → Accounts →"
    say "Apple-ID → Manage Certificates → + Apple Development."
fi

# --- 2. Checkout holen ---------------------------------------------------------
if [ ! -d "$MT_DIR/.git" ]; then
    say "Erster Lauf: hole den Fork nach $MT_DIR"
    mkdir -p "$(dirname "$MT_DIR")"
    git clone --quiet "$FORK_URL" "$MT_DIR"
fi
cd "$MT_DIR"
git remote get-url upstream >/dev/null 2>&1 || git remote add upstream "$UPSTREAM_URL"
git config user.name >/dev/null || git config user.name "mt-update"
git config user.email >/dev/null || git config user.email "mt-update@localhost"
git fetch --quiet --prune origin
git fetch --quiet upstream main

# --- 3. Eigene Branches bestimmen ----------------------------------------------
pr_merged() {  # 0 = PR zu diesem Branch ist im Original übernommen
    # Eingereicht wird entweder der Branch selbst oder seine Kopie submit/<name>
    # (submit.sh), darum beide Köpfe prüfen.
    local json head
    for head in "$1" "submit/${1#*/}"; do
        json="$(curl -fsS "$UPSTREAM_API/pulls?state=closed&head=$FORK_OWNER:$head" 2>/dev/null || true)"
        printf '%s' "$json" | grep -q '"merged_at": *"20' && return 0
    done
    return 1
}
if [ -n "${MT_BRANCHES:-}" ]; then
    wanted="$(printf '%s\n' $MT_BRANCHES)"
else
    wanted="$(git show origin/tools:branches.txt 2>/dev/null)" \
        || fail "branches.txt auf dem Branch tools des Forks nicht gefunden"
fi
branches=()
skipped=()
while read -r b; do
    b="${b%%#*}"; b="$(printf '%s' "$b" | tr -d '[:space:]')"
    [ -n "$b" ] || continue
    git rev-parse --verify --quiet "origin/$b" >/dev/null || fail "Branch $b fehlt im Fork"
    if [ -z "$(git cherry upstream/main "origin/$b" | grep '^+' || true)" ] || pr_merged "$b"; then
        skipped+=("$b")
    else
        branches+=("$b")
    fi
done <<< "$wanted"

upstream_sha="$(git rev-parse --short upstream/main)"
state="upstream $upstream_sha"
for b in ${branches[@]+"${branches[@]}"}; do state+=" | $b $(git rev-parse --short "origin/$b")"; done

if $CHECK_ONLY; then
    say "Stand jetzt:        $state"
    say "Letzter Build:      $(cat "$STAMP" 2>/dev/null || echo '—')"
    [ "$state" = "$(cat "$STAMP" 2>/dev/null)" ] && say "Nichts Neues." || say "Neuer Stand verfügbar → mt-update"
    exit 0
fi

# --- 4. Zusammenführen ---------------------------------------------------------
say "Original: $upstream_sha"
git checkout --quiet --force -B mt-build upstream/main
for b in ${branches[@]+"${branches[@]}"}; do
    if git merge --quiet --no-ff --no-edit "origin/$b" >/dev/null 2>&1; then
        echo "  ✓ $b"
    else
        conflicts="$(git diff --name-only --diff-filter=U | sed 's/^/      /')"
        git merge --abort || true
        fail "Konflikt beim Mischen von $b — installierte App bleibt unverändert.
    Betroffene Dateien:
$conflicts
    Der Branch muss auf den neuen Stand des Originals gebracht werden." 2
    fi
done
for b in ${skipped[@]+"${skipped[@]}"}; do echo "  – $b (im Original enthalten, übersprungen)"; done

# --- 5. Bauen ------------------------------------------------------------------
say "Baue die App (erster Lauf 5–10 Minuten) …"
log="$(dirname "$MT_DIR")/build.log"
if ! ./scripts/run_app.sh --build-only >"$log" 2>&1; then
    tail -20 "$log" >&2
    fail "Build fehlgeschlagen — installierte App bleibt unverändert. Log: $log" 3
fi
built="$MT_DIR/app/MeetingTranscriber/.build/$APP_NAME"
[ -d "$built" ] || fail "Build meldet Erfolg, aber $built fehlt" 3

# --- 6. Warten, bis die App frei ist, dann installieren ------------------------
# Die App beendet sich beim Quit sofort und ohne Rückfrage: eine laufende
# Aufnahme endet dann abrupt (die nächste Sitzung rettet sie nur als
# Absturz-Wiederherstellung), ein laufender Job beginnt nach dem Neustart von
# vorn. Darum wird erst ersetzt, wenn nichts läuft.
target="$MT_APP_DIR/$APP_NAME"
# Verankert auf den Programmpfad: ein Shell-Befehl, der den Pfad nur erwähnt,
# zählt nicht als laufende App.
app_pid() { pgrep -f "^$target/Contents/MacOS/MeetingTranscriber" | head -1 || true; }

busy_reason() {  # leer = nichts in Arbeit; sonst kurze Begründung
    local pid started q reason="" n m
    pid="$(app_pid)"
    [ -n "$pid" ] || return 0
    # Eine Aufnahme hinterlässt einen Marker, solange sie läuft. Ein Absturz
    # lässt ihn liegen; der ist dann älter als der laufende Prozess.
    started="$(LC_ALL=C date -j -f "%a %b %d %T %Y" "$(echo $(ps -o lstart= -p "$pid"))" +%s 2>/dev/null || echo 0)"
    for m in "$MT_DATA_DIR"/recordings/*_recording.marker; do
        [ -e "$m" ] || continue
        if [ "$(stat -f %m "$m")" -ge "$started" ]; then reason+="Aufnahme läuft · "; break; fi
    done
    q="$MT_DATA_DIR/ipc/pipeline_queue.json"
    n="$(grep -oE '"state" *: *"(waiting|transcribing|diarizing|generatingProtocol)"' "$q" 2>/dev/null | wc -l | tr -d ' ')"
    [ "${n:-0}" -eq 0 ] || reason+="$n Job(s) in Arbeit · "
    printf '%s' "${reason% · }"
}

reason="$(busy_reason)"
if [ -n "$reason" ]; then
    [ -z "${MT_NO_WAIT:-}" ] || fail "App ist beschäftigt ($reason) — installierte App bleibt unverändert." 4
    say "Neue Version ist gebaut. Warte, bis die App frei ist: $reason"
    say "  (prüft alle 30 s, höchstens $(( MT_WAIT_MAX / 60 )) min; Ctrl-C bricht ab, App bleibt dann unverändert)"
    waited=0
    while reason="$(busy_reason)"; [ -n "$reason" ]; do
        [ "$waited" -lt "$MT_WAIT_MAX" ] || fail "Nach $(( MT_WAIT_MAX / 60 )) min immer noch beschäftigt ($reason) — abgebrochen, App unverändert." 4
        sleep 30; waited=$(( waited + 30 ))
    done
    say "App ist frei."
fi
naming="$(grep -oE '"state" *: *"speakerNamingPending"' "$MT_DATA_DIR/ipc/pipeline_queue.json" 2>/dev/null | wc -l | tr -d ' ')"
[ "${naming:-0}" -eq 0 ] || say "Hinweis: $naming Sprecher-Benennung(en) offen — sie erscheinen nach dem Neustart wieder; im Dialog getippte, noch nicht bestätigte Namen gehen verloren."

if [ -n "$(app_pid)" ]; then
    say "Beende die laufende App …"
    osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
    for _ in 1 2 3 4 5 6 7 8 9 10; do [ -n "$(app_pid)" ] || break; sleep 1; done
    [ -z "$(app_pid)" ] || fail "App lässt sich nicht beenden. Später nochmals." 4
fi
staging="$MT_APP_DIR/.$APP_NAME.new"
rm -rf "$staging"
ditto "$built" "$staging"
codesign --verify --deep --strict "$staging" 2>/dev/null || say "Hinweis: Signaturprüfung meldet Abweichungen (ad-hoc signiert?)"
rm -rf "$target"
mv "$staging" "$target"
echo "$state" > "$STAMP"
say "✓ Installiert: $target"
say "  Stand: $state"

if [ -z "${MT_NO_LAUNCH:-}" ]; then
    open "$target"
fi
