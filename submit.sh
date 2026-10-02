#!/usr/bin/env bash
# submit.sh — einen Feature-Branch des Forks fürs Original (pasrom) aufbereiten.
#
# Baut submit/<name> frisch auf dem neuesten upstream/main auf, mit genau den
# Code-Änderungen des Feature-Branches: Commit für Commit, Nachricht und Autor
# übernommen, ohne die flow-next-Buchhaltung unter .flow/. Bricht ab, bevor
# etwas Fork-Eigenes ins Original gelangen kann.
#
# Ohne --go passiert nur Lokales: submit/<name> wird gebaut und geprüft, nichts
# verlässt den Rechner. Mit --go wird submit/<name> in den Fork gepusht und der
# PR im Original geöffnet (Entwurf) bzw. ein bestehender aktualisiert. --go nur
# nach ausdrücklicher Freigabe des Owners.
#
# Aufruf (in einem Checkout des Forks):
#   submit.sh <branch> [--name <name>]                  nur bauen und prüfen
#   submit.sh <branch> --go --body-file <pr.md> [--title <titel>] [--ready]
#   --allow-claude-md   eine Änderung am CLAUDE.md des Originals zulassen (dort
#                       Architektur-Doku, siehe CONTRIBUTING.md); ihr Diff wird
#                       ausgegeben, damit er vor der Freigabe sichtbar ist
#
# <name> ist ohne Angabe der Branch-Name ohne Präfix (feat/hf-token → hf-token).

set -euo pipefail

FORK_SLUG="wapp-its/meeting-transcriber"
UPSTREAM_SLUG="pasrom/meeting-transcriber"
FORK_OWNER="wapp-its"
HOME_BRANCH="wapp/main"

# Pfade, die nie ins Original gehören (inkl. der Fork-Workflows wapp-*). .flow/ wird beim Übertragen bewusst
# weggelassen (Buchhaltung des Forks); die übrigen sind Änderungen, die jemand
# absichtlich gemacht hat, und dürfen nicht stillschweigend verschwinden, darum
# Abbruch statt Weglassen.
forbidden_regex='(^|/)(CLAUDE\.md|AGENTS\.md)$|^\.claude/rules/|^\.flow/|^\.github/workflows/wapp-'
# Verweise, die es nur im Fork gibt: Spec-IDs, Fork-Namen. Immer Abbruch.
reference_regex='\b(gh|fn)-[0-9]+|wapp|\.flow/'
# #N ist mehrdeutig: dieselbe Nummer gibt es im Fork und im Original. Verweise
# aufs Original (#736) sind erwünscht, darum nur Warnung mit beiden Titeln, wenn
# die Nummer auch im Fork existiert; --go verlangt dann --refs-ok.
FORK_API="https://api.github.com/repos/$FORK_SLUG"
UPSTREAM_API="https://api.github.com/repos/$UPSTREAM_SLUG"

say() { printf '\033[1m%s\033[0m\n' "$*"; }
fail() { printf '\033[31m✗ %s\033[0m\n' "$1" >&2; exit "${2:-1}"; }

branch=""; name=""; go=false; body_file=""; title=""; draft=true; allow_claude_md=false; refs_ok=false
while [ $# -gt 0 ]; do
    case "$1" in
        --name) name="$2"; shift 2 ;;
        --go) go=true; shift ;;
        --body-file) body_file="$2"; shift 2 ;;
        --title) title="$2"; shift 2 ;;
        --ready) draft=false; shift ;;
        --allow-claude-md) allow_claude_md=true; shift ;;
        --refs-ok) refs_ok=true; shift ;;
        -h|--help) sed -n '2,22p' "$0"; exit 0 ;;
        -*) fail "Unbekannte Option $1" 2 ;;
        *) [ -z "$branch" ] || fail "Nur ein Branch pro Aufruf" 2; branch="$1"; shift ;;
    esac
done
[ -n "$branch" ] || fail "Aufruf: submit.sh <branch> [--name <name>] [--go --body-file <pr.md>]" 2
name="${name:-${branch#*/}}"
# Mit --allow-claude-md fällt nur CLAUDE.md aus der Sperrliste; .claude/rules/,
# AGENTS.md und .flow/ bleiben gesperrt.
$allow_claude_md && forbidden_regex='(^|/)AGENTS\.md$|^\.claude/rules/|^\.flow/|^\.github/workflows/wapp-'
target="submit/$name"
if $go; then
    [ -n "$body_file" ] && [ -f "$body_file" ] || fail "--go braucht --body-file mit dem PR-Text" 2
fi

# --- 1. Checkout und Stand -----------------------------------------------------
repo="$(git rev-parse --show-toplevel 2>/dev/null)" || fail "Kein Git-Checkout"
cd "$repo"
case "$(git remote get-url origin 2>/dev/null)" in
    *"$FORK_SLUG"*) ;; *) fail "origin ist nicht der Fork $FORK_SLUG" ;;
esac
case "$(git remote get-url upstream 2>/dev/null)" in
    *"$UPSTREAM_SLUG"*) ;; *) fail "upstream ist nicht $UPSTREAM_SLUG" ;;
esac
git fetch --quiet --prune origin
git fetch --quiet upstream main

if git rev-parse --verify --quiet "refs/heads/$branch" >/dev/null; then
    src="refs/heads/$branch"
    if git rev-parse --verify --quiet "origin/$branch" >/dev/null \
        && [ "$(git rev-parse "$src")" != "$(git rev-parse "origin/$branch")" ]; then
        say "Hinweis: lokaler $branch weicht von origin/$branch ab — nehme den lokalen."
    fi
else
    src="origin/$branch"
    git rev-parse --verify --quiet "$src" >/dev/null || fail "Branch $branch gibt es weder lokal noch im Fork"
fi

# Basis: wo der Branch vom Heim-Branch abzweigt; ältere Branches, die direkt auf
# upstream/main aufsetzen, landen so ebenfalls auf ihrer Abzweigung.
home_ref="origin/$HOME_BRANCH"
git rev-parse --verify --quiet "$home_ref" >/dev/null || home_ref="upstream/main"
base="$(git merge-base "$src" "$home_ref")"
commits="$(git rev-list --reverse --no-merges "$base..$src")"
[ -n "$commits" ] || fail "$branch hat keine eigenen Commits gegenüber $home_ref"

# --- 2. Prüfungen vor dem Übertragen --------------------------------------------
touched="$(git diff --name-only "$base" "$src")"
blocked="$(printf '%s\n' "$touched" | grep -E "$forbidden_regex" | grep -vE '^\.flow/' || true)"
hint="    Diese Änderungen aus dem Branch nehmen (oder in einen local/*-Branch verschieben)."
printf '%s\n' "$blocked" | grep -qE '(^|/)CLAUDE\.md$' \
    && hint+=$'\n'"    Ist es Architektur-Doku fürs Original: mit --allow-claude-md zulassen."
[ -z "$blocked" ] || fail "$branch ändert Dateien, die nicht ins Original gehören:
$(printf '%s\n' "$blocked" | sed 's/^/    /')
$hint"

refs=""
for c in $commits; do
    hits="$(git log -1 --format=%B "$c" | grep -nE "$reference_regex" || true)"
    [ -z "$hits" ] || refs+="  $(git log -1 --format='%h %s' "$c")"$'\n'"$(printf '%s\n' "$hits" | sed 's/^/      /')"$'\n'
done
[ -z "$refs" ] || fail "Commit-Nachrichten verweisen auf Fork-Interna (würden im Original falsch verlinken):
$refs    Nachrichten im Branch bereinigen (z. B. git rebase -i), dann erneut."

issue_title() {  # $1 = API-Basis, $2 = Nummer → Titel oder leer
    # Eine fehlende Nummer (404) ist ein normales Ergebnis, kein Abbruch.
    { curl -fsS "$1/issues/$2" 2>/dev/null || true; } | sed -n 's/^  "title": "\(.*\)",$/\1/p' | head -1
}
ambiguous=""
for n in $(git log --format=%B "$base..$src" | grep -oE '(^|[^A-Za-z0-9&])#[0-9]+' | grep -oE '[0-9]+' | sort -un); do
    fork_title="$(issue_title "$FORK_API" "$n")"
    [ -n "$fork_title" ] || continue
    ambiguous+="    #$n  Original: $(issue_title "$UPSTREAM_API" "$n" | cut -c1-60)"$'\n'
    ambiguous+="         Fork:     $(printf '%s' "$fork_title" | cut -c1-60)"$'\n'
done

# --- 3. submit/<name> auf upstream/main aufbauen --------------------------------
tmp="$(mktemp -d)"
cleanup() { git worktree remove --force "$tmp" >/dev/null 2>&1 || true; rm -rf "$tmp"; }
trap cleanup EXIT
git worktree add --quiet --detach "$tmp" upstream/main

applied=(); skipped=()
for c in $commits; do
    patch="$(git diff-tree -p --binary --no-commit-id "$c" -- . ':(exclude).flow')"
    if [ -z "$patch" ]; then
        skipped+=("$(git log -1 --format='%h %s' "$c")")
        continue
    fi
    if ! printf '%s\n' "$patch" | git -C "$tmp" apply --index --3way >/dev/null 2>&1; then
        conflicts="$(git -C "$tmp" diff --name-only --diff-filter=U | sed 's/^/    /')"
        fail "$(git log -1 --format='%h %s' "$c") passt nicht auf upstream/main:
${conflicts:-    (Patch nicht anwendbar)}
    Den Branch zuerst auf den neuen Stand des Originals bringen." 3
    fi
    git -C "$tmp" commit --quiet --no-verify -C "$c"
    applied+=("$(git log -1 --format='%h %s' "$c")")
done
[ ${#applied[@]} -gt 0 ] || fail "Nach Abzug von .flow/ bleibt keine Code-Änderung übrig"

# Letzte Sicherung auf dem Ergebnis selbst, unabhängig davon, wie es entstand.
leak="$(git -C "$tmp" diff --name-only upstream/main HEAD | grep -E "$forbidden_regex" || true)"
[ -z "$leak" ] || fail "submit-Ergebnis enthält Fork-Dateien — abgebrochen:
$(printf '%s\n' "$leak" | sed 's/^/    /')"

git branch --force "$target" "$(git -C "$tmp" rev-parse HEAD)" >/dev/null

say "✓ $target gebaut auf upstream/main $(git rev-parse --short upstream/main)"
for a in "${applied[@]}"; do echo "  + $a"; done
for s in ${skipped[@]+"${skipped[@]}"}; do echo "  – $s (nur .flow/, weggelassen)"; done
git diff --stat upstream/main "$target" | tail -1
claude_md_diff="$(git diff upstream/main "$target" -- 'CLAUDE.md' '**/CLAUDE.md')"
if [ -n "$claude_md_diff" ]; then
    say "Änderung am CLAUDE.md des Originals (mit --allow-claude-md zugelassen):"
    printf '%s\n' "$claude_md_diff"
fi

if [ -n "$ambiguous" ]; then
    say "⚠ Diese #-Verweise gibt es auch im Fork — im Original zeigen sie auf das Issue des Originals:"
    printf '%s' "$ambiguous"
fi

if ! $go; then
    extra=""; [ -n "$claude_md_diff" ] && extra+=" --allow-claude-md"
    [ -n "$ambiguous" ] && extra+=" --refs-ok"
    say "Nur lokal gebaut. Einreichen (nach Freigabe): submit.sh $branch$extra --go --body-file <pr.md>"
    exit 0
fi
[ -z "$ambiguous" ] || $refs_ok || fail "Mehrdeutige #-Verweise (siehe oben): geprüft? Dann mit --refs-ok" 2

# --- 4. Einreichen (nur mit --go) -----------------------------------------------
token="$(gh auth token --user "$FORK_OWNER" 2>/dev/null)" || fail "gh ist für $FORK_OWNER nicht angemeldet"
# Der Token geht nur über einen einmaligen Credential-Helper an git, nie in eine Config.
git -c credential.helper= \
    -c "credential.helper=!f() { echo username=$FORK_OWNER; echo password=\$(gh auth token --user $FORK_OWNER); }; f" \
    push --quiet --force-with-lease origin "$target:$target"
say "✓ $target in den Fork gepusht"

existing="$(GH_TOKEN="$token" gh pr list --repo "$UPSTREAM_SLUG" --head "$target" --state open \
    --json url,headRepositoryOwner --jq ".[] | select(.headRepositoryOwner.login == \"$FORK_OWNER\") | .url")"
if [ -n "$existing" ]; then
    say "✓ Bestehender PR aktualisiert: $existing"
    exit 0
fi
if [ -z "$title" ]; then
    [ ${#applied[@]} -eq 1 ] || fail "Mehrere Commits: --title für den PR angeben" 2
    title="$(git log -1 --format=%s "$target")"
fi
draft_flag=(); $draft && draft_flag=(--draft)
url="$(GH_TOKEN="$token" gh pr create --repo "$UPSTREAM_SLUG" --base main \
    --head "$FORK_OWNER:$target" --title "$title" --body-file "$body_file" ${draft_flag[@]+"${draft_flag[@]}"})"
say "✓ PR im Original geöffnet: $url"
