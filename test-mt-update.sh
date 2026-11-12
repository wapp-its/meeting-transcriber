#!/usr/bin/env bash
# Tests für `mt-update --check` und `mt-update --check --porcelain`, ohne Netz und
# ohne die echte App: Fork und Original sind lokale Bare-Repos in einem
# Temp-Ordner, curl, xcodebuild und security sind Attrappen, und jedes Programm,
# mit dem mt-update installieren oder die App beenden würde, schlägt an.
# Geprüft wird der Vertrag, den die App liest (MtUpdatePorcelain in
# app/MeetingTranscriber/Sources/MtUpdateContract.swift auf wapp/main):
# Zeilen format=, status=, summary= und Exit 0 / 10 / sonst.
#
# Aufruf:  bash test-mt-update.sh
# Läuft alle Fälle mit /bin/bash (3.2, macOS) und mit dem bash im PATH.

set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
script="$here/mt-update.sh"
root="$(mktemp -d)"
trap 'rm -rf "$root"' EXIT
git_dir="$(dirname "$(command -v git)")"
format="format=mt-update-porcelain/1"
esc=$'\033'

failures=0
check() {  # $1 = Fall, $2 = erwartet, $3 = erhalten
    if [ "$2" = "$3" ]; then
        printf '  ok    %s\n' "$1"
    else
        printf '  FAIL  %s\n        erwartet: %s\n        erhalten: %s\n' "$1" "$2" "$3"
        failures=$(( failures + 1 ))
    fi
}

commit() {  # $1 = Repo, $2 = Datei, $3 = Inhalt
    printf '%s\n' "$3" > "$1/$2"
    git -C "$1" add "$2"
    git -C "$1" commit -q -m "$3"
}

# Original (main) und Fork (wapp/main, local/diag, feat/merged, tools mit
# branches.txt) als Bare-Repos; feat/merged steckt schon im Original und fällt weg.
setup() {
    D="$1"
    mkdir -p "$D/bin" "$D/home" "$D/support"
    export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL="$D/gitconfig"
    printf '[user]\n\tname = t\n\temail = t@example.invalid\n[commit]\n\tgpgsign = false\n[init]\n\tdefaultBranch = main\n' \
        > "$GIT_CONFIG_GLOBAL"
    W="$D/work"
    git init -q "$W"
    commit "$W" README base
    git clone -q --bare "$W" "$D/upstream.git"
    git clone -q --bare "$W" "$D/fork.git"
    git -C "$W" checkout -q -b wapp/main main && commit "$W" wapp.txt wapp
    git -C "$W" checkout -q -b local/diag main && commit "$W" diag.txt diag
    git -C "$W" checkout -q -b feat/merged main && commit "$W" merged.txt merged
    git -C "$W" checkout -q --orphan tools
    git -C "$W" rm -q -rf .
    commit "$W" branches.txt "$(printf '# Kommentar\nwapp/main\nlocal/diag\nfeat/merged')"
    git -C "$W" push -q "$D/fork.git" wapp/main local/diag feat/merged tools
    git -C "$W" checkout -q main
    git -C "$W" cherry-pick feat/merged >/dev/null
    git -C "$W" push -q "$D/upstream.git" main

    MT="$D/support/meeting-transcriber"
    STAMP="$D/support/last-build.txt"
    git clone -q "$D/fork.git" "$MT"
    git -C "$MT" remote add upstream "$D/upstream.git"

    printf '#!/bin/sh\nprintf "Xcode 26.1\\nBuild version 17B1\\n"\n' > "$D/bin/xcodebuild"
    printf '#!/bin/sh\nprintf "  1) 0123 \\"Apple Development: Test\\"\\n"\n' > "$D/bin/security"
    # Für pr_merged: kein PR im Original übernommen. Nie ein Netzzugriff.
    printf '#!/bin/sh\necho "$*" >> "%s/curl.log"\necho "[]"\n' "$D" > "$D/bin/curl"
    for p in osascript open ditto codesign pgrep install; do
        printf '#!/bin/sh\necho "%s $*" >> "%s/forbidden.log"\nexit 1\n' "$p" "$D" > "$D/bin/$p"
    done
    chmod +x "$D"/bin/*
}

short() { git -C "$MT" rev-parse --short "$1"; }

EXTRA_ENV=()
# Startet mt-update.sh wie die App: leere Umgebung (kein LANG), stdin /dev/null,
# Arbeitsordner HOME. Setzt code, out (stdout), err (stderr).
run() {  # $1 = bash, Rest = Argumente
    local sh="$1"
    shift
    set +e
    (cd "$D/home" && env -i HOME="$D/home" PATH="$D/bin:$git_dir:/usr/bin:/bin" \
        GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL="$D/gitconfig" GIT_TERMINAL_PROMPT=0 \
        MT_DIR="$MT" MT_APP_DIR="$D/Applications" MT_DATA_DIR="$D/data" MT_NO_SELF_UPDATE=1 \
        ${EXTRA_ENV[@]+"${EXTRA_ENV[@]}"} \
        "$sh" "$script" "$@" < /dev/null > "$D/out" 2> "$D/err")
    code=$?
    set -e
    out="$(cat "$D/out")"
    err="$(cat "$D/err")"
}

# Nach jedem Lauf: nichts gebaut, installiert, beendet; Stand-Datei unverändert.
read_only() {  # $1 = Fall, $2 = Stand-Datei vorher
    check "$1: Stand-Datei unverändert" "$2" "$(cat "$STAMP" 2>/dev/null || echo '<keine>')"
    check "$1: nichts installiert oder beendet" "" "$(cat "$D/forbidden.log" 2>/dev/null || true)"
    check "$1: kein Zielordner angelegt" "no" "$([ -e "$D/Applications" ] && echo yes || echo no)"
    check "$1: Checkout steht auf main" "refs/heads/main" "$(git -C "$MT" symbolic-ref HEAD)"
    check "$1: kein Build-Branch" "" "$(git -C "$MT" branch --list mt-build)"
    check "$1: Arbeitskopie sauber" "" "$(git -C "$MT" status --porcelain)"
}

no_ansi() {  # $1 = Fall
    case "$out$err" in *"$esc"*) check "$1: keine ANSI-Farben" no yes ;; *) check "$1: keine ANSI-Farben" no no ;; esac
}

porcelain() {  # $1 = bash, $2 = Fall; prüft Lesbarkeit und Unverändertheit
    local before
    before="$(cat "$STAMP" 2>/dev/null || echo '<keine>')"
    run "$1" --check --porcelain
    read_only "$2" "$before"
    no_ansi "$2"
}

suite() {  # $1 = bash
    local sh="$1" u w d s want
    # shellcheck disable=SC2016  # $BASH_VERSION gehört der Shell unter Test
    echo "== $sh ($("$sh" -c 'echo $BASH_VERSION'))"
    setup "$root/$(echo "$sh" | tr '/' '_')"

    # 1. Noch nie gebaut: alles ist neu.
    porcelain "$sh" "ohne Stand-Datei"
    u="$(short upstream/main)"; w="$(short origin/wapp/main)"; d="$(short origin/local/diag)"
    check "ohne Stand-Datei: Exit 10" 10 "$code"
    check "ohne Stand-Datei: stdout" \
        "$format"$'\n'"status=update-available"$'\n'"summary=upstream $u · wapp/main $w · local/diag $d" "$out"

    # 2. Stand-Datei = was ein Lauf jetzt bauen würde.
    echo "upstream $u | wapp/main $w | local/diag $d" > "$STAMP"
    porcelain "$sh" "aktuell"
    check "aktuell: Exit 0" 0 "$code"
    check "aktuell: stdout" "$format"$'\n'"status=up-to-date" "$out"

    # 3. Neuer Commit im Original: nur der geänderte Teil steht in summary.
    commit "$W" upstream.txt "neu im Original"
    git -C "$W" push -q "$D/upstream.git" main
    porcelain "$sh" "neues Original"
    u="$(short upstream/main)"
    check "neues Original: Exit 10" 10 "$code"
    check "neues Original: stdout" \
        "$format"$'\n'"status=update-available"$'\n'"summary=upstream $u" "$out"

    # 4. Ein früher eingemischter Branch fällt weg (im Original übernommen).
    echo "upstream $u | wapp/main $w | local/diag $d | feat/merged 1234567" > "$STAMP"
    porcelain "$sh" "Branch fällt weg"
    check "Branch fällt weg: Exit 10" 10 "$code"
    check "Branch fällt weg: summary" "summary=without feat/merged" "$(printf '%s\n' "$out" | grep '^summary=')"

    # 5. Zu viele Änderungen für 80 Zeichen: ganze Teile, der Rest als "+N more".
    for i in 1 2 3 4; do
        git -C "$W" checkout -q -B "feat/long-name-for-summary-test-$i" main
        commit "$W" "long$i.txt" "long $i"
        git -C "$W" push -q "$D/fork.git" "feat/long-name-for-summary-test-$i"
    done
    git -C "$W" checkout -q main
    EXTRA_ENV=("MT_BRANCHES=feat/long-name-for-summary-test-1 feat/long-name-for-summary-test-2 feat/long-name-for-summary-test-3 feat/long-name-for-summary-test-4")
    rm -f "$STAMP"
    porcelain "$sh" "lange summary"
    EXTRA_ENV=()
    s="$(printf '%s\n' "$out" | sed -n 's/^summary=//p')"
    want="upstream $u · feat/long-name-for-summary-test-1 $(short origin/feat/long-name-for-summary-test-1) · +3 more"
    check "lange summary: Exit 10" 10 "$code"
    check "lange summary: ganze Teile, Rest gezählt" "$want" "$s"
    check "lange summary: höchstens 80 Zeichen" yes \
        "$([ "$(printf '%s' "$s" | LC_ALL=en_US.UTF-8 wc -m | tr -d ' ')" -le 80 ] && echo yes || echo no)"
    check "lange summary: gültiges UTF-8" yes \
        "$(printf '%s' "$s" | iconv -f UTF-8 -t UTF-8 >/dev/null 2>&1 && echo yes || echo no)"

    # 6. Ein einzelner Teil über 80 Zeichen wird gekürzt.
    git -C "$W" checkout -q -B "feat/$(printf 'x%.0s' $(seq 1 90))" main
    commit "$W" x.txt x
    git -C "$W" push -q "$D/fork.git" "feat/$(printf 'x%.0s' $(seq 1 90))"
    git -C "$W" checkout -q main
    EXTRA_ENV=("MT_BRANCHES=feat/$(printf 'x%.0s' $(seq 1 90))")
    echo "upstream $u" > "$STAMP"
    porcelain "$sh" "ein langer Teil"
    EXTRA_ENV=()
    s="$(printf '%s\n' "$out" | sed -n 's/^summary=//p')"
    check "ein langer Teil: auf 80 Zeichen gekürzt" "feat/$(printf 'x%.0s' $(seq 1 75))" "$s"

    # 7. Offline / Original nicht erreichbar: Exit weder 0 noch 10, keine Antwort.
    echo "upstream $u | wapp/main $w | local/diag $d" > "$STAMP"
    mv "$D/upstream.git" "$D/upstream.off"
    porcelain "$sh" "offline"
    mv "$D/upstream.off" "$D/upstream.git"
    check "offline: Exit weder 0 noch 10" yes "$([ "$code" -ne 0 ] && [ "$code" -ne 10 ] && echo yes || echo no)"
    check "offline: keine status-Zeile" "" "$(printf '%s\n' "$out" | grep '^status=' || true)"

    # 8. --check ohne --porcelain: Text für Menschen wie bisher, Exit 0.
    run "$sh" --check
    check "--check: Exit 0" 0 "$code"
    check "--check: meldet 'Nichts Neues.'" "Nichts Neues." "$(printf '%s\n' "$out" | tail -1)"
    no_ansi "--check"

    # 9. --porcelain allein und unbekannte Argumente bauen nie.
    run "$sh" --porcelain
    check "--porcelain allein: Exit 1" 1 "$code"
    check "--porcelain allein: stdout leer" "" "$out"
    run "$sh" --chek
    check "unbekanntes Argument: Exit 1" 1 "$code"
    read_only "falsche Argumente" "$(cat "$STAMP")"
}

shells=(/bin/bash)
path_bash="$(command -v bash)"
[ "$path_bash" = /bin/bash ] || shells+=("$path_bash")
for sh in "${shells[@]}"; do suite "$sh"; done

if [ "$failures" -eq 0 ]; then
    echo "Alle Tests bestanden."
else
    echo "$failures Test(s) fehlgeschlagen."
    exit 1
fi
