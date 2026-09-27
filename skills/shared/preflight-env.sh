#!/usr/bin/env bash
# preflight-env.sh — report what THIS environment can actually do.
#
# Written for a session that did not configure the machine it runs on: a review session in a
# sandbox, whose config.yaml, reachable providers and git remote are not the ones the prompt
# was written against. It prints one row per capability and a SUMMARY block naming the
# reviewers that can be selected here.
#
# EVERY verdict exits 0 — "nothing is reachable" is an answer, not a failure. A non-zero exit
# means this script is broken, could not start (64, the bash-4 check below — stock macOS bash
# is 3.2, exactly the machine this probe exists for) or was interrupted (130/143) — never that
# the environment is poor (same contract as shared/watch-runs.sh).
#
# Env: PREFLIGHT_HTTP_TIMEOUT (5)  PREFLIGHT_GIT_TIMEOUT (8)  PREFLIGHT_CLI_TIMEOUT (15)
#      PREFLIGHT_CURL_BIN (curl)   PREFLIGHT_GIT_BIN (git)
#      PREFLIGHT_YQ_BIN (yq)       PREFLIGHT_JQ_BIN (jq)
#      PREFLIGHT_EXT_DEPS_BINS ("claude bc python3")
#      PREFLIGHT_SKIP_NETWORK (0)  — 1 skips every network probe (fast re-runs)
set -u

# Bash 4+ required: PROBED_STATUS is an associative array. Exit 64 — not 1 — for the same
# reason watch-runs.sh does: a bare 1 is indistinguishable from a verdict, and this probe's
# whole job is to run on a machine nobody configured (macOS system bash is 3.2). "Every
# verdict exits 0" covers DELIVERED verdicts; a probe that cannot run delivers none.
if [ "${BASH_VERSINFO[0]:-0}" -lt 4 ]; then
    echo "preflight-env: bash 4+ required (got ${BASH_VERSION:-unknown}). Install: brew install bash" >&2
    exit 64
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOADER="$SCRIPT_DIR/config-loader.sh"
EXEC_DIR="$SCRIPT_DIR/../ext-claude-exec"
HTTP_TIMEOUT="${PREFLIGHT_HTTP_TIMEOUT:-5}"
GIT_TIMEOUT="${PREFLIGHT_GIT_TIMEOUT:-8}"
# A command probe is not an HTTP probe and must not share its budget. `grok models` is a full
# CLI start plus an authenticated round-trip, where codex's and gemini's probes are a curl that
# answers in milliseconds. Measured 2026-08-30 on grok 1.0.13, eight warm runs: 1.83-2.30s,
# essentially unmoved by CPU load (1.79-1.98s under four busy loops), so the cost is network and
# I/O, not compute. The design measured 1.0-1.2s on grok 1.0.5 and wrote its 5s budget around
# "roughly fourfold headroom" — that premise is gone, halved by one CLI version bump, and a COLD
# start has never been measured by anyone. Own budget rather than a raise of the shared one, and
# the size follows PREFLIGHT_GIT_TIMEOUT's precedent one line above: the design names both.
#
# The error this buys protection from is a FALSE NEGATIVE, which is why it is worth a slower
# failure: a slow-but-healthy CLI timing out prints "no network, or not logged in" as a fact,
# drops grok from SUMMARY, and the *-fresh-session commands read exactly that SUMMARY to decide
# whether `default` is safe. The cost is that a genuinely offline machine waits 15s on this one
# row instead of 5s.
CLI_TIMEOUT="${PREFLIGHT_CLI_TIMEOUT:-15}"
# Budgets are pasted straight into `curl --max-time` and `timeout`, so an unusable value here
# does not degrade — it INVENTS a verdict, which is the one thing this file never does. Three
# ways it went wrong, all observed: `PREFLIGHT_GIT_TIMEOUT=--help` makes `timeout` print its
# usage and exit 0 WITHOUT running git, and the row then read `git-remote OK  origin answered`
# about a remote nothing had contacted; a non-numeric value came back as a confident
# `NO-NETWORK … within abcs`; and `0` means "no timeout at all" to curl, so a probe advertised
# as bounded could hang forever. Normalised once, here, for the same reason SKIP_NET is below:
# a positive integer or the documented default, with nothing in between.
case "$HTTP_TIMEOUT" in ''|*[!0-9]*|0) HTTP_TIMEOUT=5 ;; esac
case "$GIT_TIMEOUT"  in ''|*[!0-9]*|0) GIT_TIMEOUT=8  ;; esac
case "$CLI_TIMEOUT"  in ''|*[!0-9]*|0) CLI_TIMEOUT=15 ;; esac
CURL_BIN="${PREFLIGHT_CURL_BIN:-curl}"
GIT_BIN="${PREFLIGHT_GIT_BIN:-git}"
YQ_BIN="${PREFLIGHT_YQ_BIN:-yq}"
JQ_BIN="${PREFLIGHT_JQ_BIN:-jq}"
EXT_DEPS_BINS="${PREFLIGHT_EXT_DEPS_BINS:-claude bc python3}"
SKIP_NET="${PREFLIGHT_SKIP_NETWORK:-0}"
# Normalise ONCE, here, so the flag cannot be half-honoured. Its three consumers do not test it
# the same way — probe_http asks "is it 0?" (skips on anything else), the provider loop and the
# git row ask "is it 1?" (probe on anything else) — so PREFLIGHT_SKIP_NETWORK=true used to skip
# the CLI probes and still spend the git budget on the operator's real remote. Anything that is
# not exactly 0 now means 1: a flag whose whole purpose is "touch nothing" must fail toward
# touching nothing. (Fixing it here rather than at the three call sites keeps them literally as
# the plan wrote them, and keeps the next consumer from having to know which convention to pick.)
[ "$SKIP_NET" = 0 ] || SKIP_NET=1

# Task 2 sets these to the private directory it is about to hand the loader, and to the env
# file that appears inside it; the trap removes both even if the probe is interrupted between
# export and rm. The file carries a provider token. On INT/TERM the probe exits NON-zero after
# cleanup: an interrupt is not a verdict — "every verdict exits 0" covers completed runs only.
# (This is also why probe_provider must never run inside a command substitution: a value
# assigned in a subshell never reaches this trap.)
#
# The DIRECTORY is what closes the interrupt window, and naming the file alone cannot: the
# loader creates and fills the token file INSIDE the command substitution, so between its
# mktemp and the moment it prints the path there is a window — measured at ~17 ms per provider
# — in which the file is on disk and nothing here names it. A signal delivered to the process
# GROUP during that window (what Ctrl+C at a terminal does) killed the loader and left a
# mode-600 token file behind; the parent read the dead child as an ordinary "export refused"
# and exited 0, so nothing reported the orphan. A directory created BEFORE export runs removes
# the window outright: there is nothing the loader can create that the trap does not cover.
CURRENT_ENVD=""
CURRENT_ENVF=""
# SC2317: reached only through the traps below, and since the summary section ends the file in
# an explicit `exit 0` shellcheck 0.9's reachability pass stops seeing that. Deleting the body
# on the strength of that note would leave a mode-600 token file behind on every interrupt.
# shellcheck disable=SC2317
cleanup() {
    [ -n "$CURRENT_ENVF" ] && rm -f "$CURRENT_ENVF"
    [ -n "$CURRENT_ENVD" ] && rm -rf "$CURRENT_ENVD"
    return 0
}
trap cleanup EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM

# 18, not 16: `provider:deepseek` is 17 characters and any 8-character provider id overflows a
# 16-wide pad, which pushes the status column right on exactly the row a reader is scanning for
# a red verdict. Every gate that parses this table splits on whitespace (awk $1/$2), so the pad
# is presentation only — but this table IS the deliverable the generated prompts tell a session
# to print verbatim, so a ragged column is a defect in the product, not a cosmetic detail.
#
# 18 is not "wide enough" either, and no fixed number is: `provider:openrouter` is 19 characters
# and needs nothing but an operator writing that id in their own config.yaml. The width is
# deliberately NOT computed from the rows, and this is the trade: computing it means buffering
# every row until the last provider has been probed, and the rows ARE the progress signal —
# a full sequential run takes 25-50 s and prints nothing else while it works. A reader watching
# a silent terminal cannot tell a slow probe from a hung one. One ragged row on an unusual
# provider id costs less than that, so an overflow here is a known cost, not an oversight.
row() { printf '%-18s %-12s %s\n' "$1" "$2" "${3:-}"; }

# EVERY temp file in this probe comes from here, and every caller checks the return. An
# unwritable or full TMPDIR is not exotic on the machines this probe exists for, and an
# unchecked mktemp fails in the one direction this file never tolerates: the empty name turns
# `cmd 2>"$f"` into an ambiguous redirect, which fails the command it was only supposed to
# watch — so the probe reports a verdict about a config it never read, and prints mktemp's and
# head's own complaints on the stderr that must carry probe chatter and nothing else.
# The emptiness test is not redundant with the exit code: a name is only usable if BOTH hold.
mktemp_or_fail() {      # echoes a temp-file path; non-zero and silent when it cannot
    local f
    f="$(mktemp 2>/dev/null)" || return 1
    [ -n "$f" ] || return 1
    printf '%s\n' "$f"
}

# Same contract for a directory. This one exists for exactly one caller — the private dir the
# loader writes its token file into — so the trap can name the target BEFORE export creates
# anything inside it. Both conditions matter here for the same reason as above: `rm -rf ""`
# would be a silent no-op that leaves the token file wherever the loader actually put it.
mktemp_dir_or_fail() {  # echoes a temp-dir path; non-zero and silent when it cannot
    local d
    d="$(mktemp -d 2>/dev/null)" || return 1
    [ -n "$d" ] || return 1
    printf '%s\n' "$d"
}

# ---------------------------------------------------------------- identity
# Which probe is this? The reading session must be able to tell "the probe is old" from
# "the capability is absent", and a stale cache pick must be visible instead of silent.
# sed, not jq: this row prints before the toolchain check.
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PLUGIN_VERSION="$(sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
    "$PLUGIN_ROOT/.claude-plugin/plugin.json" 2>/dev/null | head -1)"
row plugin OK "${PLUGIN_VERSION:-unknown} @ $PLUGIN_ROOT"

# ---------------------------------------------------------------- toolchain
# The loader dies rc=1 without yq/jq — the same exit code a rejected config produces. Check
# first, so a dead toolchain cannot impersonate INVALID and send the operator to "fix" a
# healthy config.yaml (row names are canonical yq/jq whatever the override points at).
TOOLCHAIN_OK=1
# WHICH tool is missing decides the fix the summary hints at the bottom — "install a yq that
# emits JSON", which offers both flavors and lets the operator pick, is not the same advice as
# `apt install jq`, and by then the rows printed here can no longer be read back.
TOOLCHAIN_MISSING=""
# TWO lookups per tool, not one — the same rule the curl gate below states, for the same reason:
# PREFLIGHT_YQ_BIN / PREFLIGHT_JQ_BIN govern what THIS script checks, while config-loader.sh
# resolves bare `yq` / `jq` from PATH (config-loader.sh's `require_yq`, and the `command -v jq`
# in `load_or_die`). An override pointing at a working binary while PATH holds none used to
# satisfy this gate and come back as `config INVALID` — precisely the impersonation the
# paragraph above says cannot happen.
toolchain_row() {       # $1 = canonical name the loader looks for, $2 = the override this script uses
    local canon="$1" bin="$2" gap=""
    command -v "$bin" >/dev/null 2>&1 || gap="$bin"
    if [ "$bin" != "$canon" ] && ! command -v "$canon" >/dev/null 2>&1; then
        gap="${gap:+$gap, }$canon on PATH (where the loader looks)"
    fi
    if [ -z "$gap" ]; then
        # Present under both names: say WHICH one. Both yq flavors are accepted now, and which
        # is installed changes the transcode form and the loader's speed, so a silent success
        # leaves the reading session guessing. The banner comes from $bin, matching this
        # function's contract that the override governs what THIS script checks. The row does
        # NOT name the working invocation: deriving that would duplicate the loader's decision,
        # and re-deriving a verdict made elsewhere is exactly what this file forbids. So this OK
        # reports PRESENCE, not capability — a yq that emits no JSON still gets one, and the
        # config row below carries the real diagnosis. A known cost, and the cheaper half of the
        # trade.
        row "$canon" OK "$("$bin" --version 2>&1 | head -1)"
        return 0
    fi
    TOOLCHAIN_OK=0
    TOOLCHAIN_MISSING="${TOOLCHAIN_MISSING:+$TOOLCHAIN_MISSING, }$canon"
    row "$canon" MISSING "loader cannot run without it (missing: $gap)"
}
toolchain_row yq "$YQ_BIN"
toolchain_row jq "$JQ_BIN"

# ---------------------------------------------------------------- config
CONFIG_STATUS=""
CONFIG_DETAIL=""
MODELS=""
# The CLI-reviewer gates are initialised HERE, outside the CONFIG_STATUS=OK branch that reads
# them: cli_row runs unconditionally, so on any path where the config is not usable `set -u`
# would abort the whole probe on an unbound flag — killing rows, and the SUMMARY, that have
# nothing to do with the section in question.
HAS_CODEX=0
HAS_GEMINI=0
HAS_GROK=0
# WHICH way the probe failed to decide. UNKNOWN has more than one cause and their fixes have
# nothing in common, so the blocker hint at the bottom branches on this rather than guessing
# from TOOLCHAIN_MISSING — see the case there. Set it wherever CONFIG_STATUS becomes UNKNOWN.
CONFIG_UNKNOWN_CAUSE=""
# Same idea for MISSING, which also has two causes whose fixes share nothing: "no config.yaml
# yet" is fixed by copying the example, "the loader is not where it should be" is a broken
# install that copying a config does not touch. The hint at the bottom branches on this.
CONFIG_MISSING_CAUSE=""
# "No config.yaml yet" has a case of its own that needs different advice: the first run after
# the rename from claude-mesh, when the config still sits in Claude Code's plugin-data dir. The
# loader names that copy and prints the command that moves it; copying the example instead would
# start a blank config beside the one holding the provider tokens. Both values are read back
# from the loader's stderr, never re-derived here: the old-config search has one owner.
CONFIG_OLD_PATH=""
CONFIG_MOVE_CMD=""

if [ "$TOOLCHAIN_OK" = 0 ]; then
    CONFIG_STATUS="UNKNOWN"
    CONFIG_UNKNOWN_CAUSE="toolchain"
    CONFIG_DETAIL="cannot evaluate — loader toolchain missing (see rows above)"
elif [ ! -f "$LOADER" ]; then
    # -f, not -x: a shared-folder mount — the environment this probe exists for — drops the
    # exec bit, and a readable loader sitting right there was reported as an absent one. Every
    # invocation goes through `bash "$LOADER"` for the same reason, which is also why the
    # generated PREFLIGHT block runs the probe itself as `bash "$PF"`.
    CONFIG_STATUS="MISSING"
    CONFIG_MISSING_CAUSE="install"
    CONFIG_DETAIL="config-loader.sh not found at $LOADER — broken install"
elif ! LERR="$(mktemp_or_fail)"; then
    # Before the loader is invoked, so nothing here is a claim about config.yaml: without the
    # file to catch its stderr the read below would fail on the redirect alone and be reported
    # as INVALID — a healthy config accused of being malformed, with no detail to argue back.
    CONFIG_STATUS="UNKNOWN"
    CONFIG_UNKNOWN_CAUSE="tmpfile"
    CONFIG_DETAIL="cannot evaluate — no temp file could be created (TMPDIR unwritable or full)"
else
    # A bare $() swallows the loader's exit code, and rc=2 (no config yet) must not be
    # misread as rc=1 (config rejected) — the same distinction every caller in this repo makes.
    MODELS="$(bash "$LOADER" list-models 2>"$LERR")"; LRC=$?
    case "$LRC" in
        0) CONFIG_STATUS="OK";      CONFIG_DETAIL="$(bash "$LOADER" config-path 2>/dev/null)"
           # config OK must mean "the orchestrator starts here": mesh-design-review Step 5.0
           # dies on defaults/runtime too, not only on providers/models. One preset name is
           # enough — get-defaults runs validate_defaults for the whole defaults: section.
           # codex/gemini stay out of this gate on purpose: a broken optional section fails
           # its own row (typed getter in Task 3), never the whole environment.
           for CHECK in "get-defaults design_review" "get-flag dispatch_model"; do
               # Same guard as the LERR one above, and it matters more here: this branch is
               # reached only after the loader ANSWERED, so an OK is already on the table and
               # an unchecked failure would downgrade a config that just proved itself.
               if ! CH_ERR="$(mktemp_or_fail)"; then
                   CONFIG_STATUS="UNKNOWN"; CONFIG_UNKNOWN_CAUSE="tmpfile"
                   CONFIG_DETAIL="cannot finish the check — no temp file could be created (TMPDIR unwritable or full)"
                   MODELS=""; break
               fi
               # shellcheck disable=SC2086
               if ! bash "$LOADER" $CHECK >/dev/null 2>"$CH_ERR"; then
                   CONFIG_STATUS="INVALID"; CONFIG_DETAIL="$(head -1 "$CH_ERR")"; MODELS=""
                   rm -f "$CH_ERR"; break
               fi
               rm -f "$CH_ERR"
           done ;;
        2) CONFIG_STATUS="MISSING"; CONFIG_MISSING_CAUSE="noconfig"; CONFIG_DETAIL="no config.yaml here — the review skills will not start; the blocker hint below names the path"; MODELS=""
           # Two lines of the loader's message and nothing else from it (config-loader.sh,
           # load_or_die): "The claude-mesh config is still at <old>. Move it:" and the
           # mkdir/cp/chmod command on the line after. Both carry paths only — the loader tests
           # that the old file exists and never opens it. Matching its wording is the cost, as
           # for the toolchain causes below; the old-config scenario in test-preflight-env.sh
           # keeps the two in step. No match leaves both empty and the hint on the example.
           CONFIG_OLD_PATH="$(sed -n 's/^The claude-mesh config is still at \(.*\)\. Move it:$/\1/p' "$LERR" | head -1)"
           CONFIG_MOVE_CMD="$(awk 'hit { sub(/^[ \t]+/, ""); if (/^mkdir -p .* && cp .* && chmod 600 /) print; exit }
                                   /^The claude-mesh config is still at .*\. Move it:$/ { hit = 1 }' "$LERR")" ;;
        *) # rc=1 means "the loader refused", which is not the same as "the config is bad":
           # require_yq and require_gnu_coreutils die with this very code BEFORE config.yaml is
           # opened. The presence check above cannot catch those two — a `yq` that is present under
           # the name the loader looks for can still be one the loader cannot use — it emits
           # no JSON, or it resolves YAML 1.1 — and the presence check above passes it.
           # Calling that INVALID sends the operator to edit a file the loader never read, so
           # it is routed to the toolchain cause and its "install a yq that emits JSON" hint
           # instead. Matching on the loader's own wording is the cost; the Go-yq scenario in
           # test-preflight-env.sh is what keeps the two in step.
           CONFIG_DETAIL="$(head -1 "$LERR")"; MODELS=""
           case "$CONFIG_DETAIL" in
               *"yq not found"*|*"yq cannot produce JSON"*|*"yq mis-resolves"*)
                   CONFIG_STATUS="UNKNOWN"; CONFIG_UNKNOWN_CAUSE="toolchain"
                   # The presence gate passed, so TOOLCHAIN_MISSING is empty and the hint would
                   # degrade to "see README Dependencies". The loader just named the tool — carry
                   # that through, so the advice stays "install a yq that emits JSON" instead of the
                   # generic toolchain fallback.
                   TOOLCHAIN_MISSING="${TOOLCHAIN_MISSING:-yq}" ;;
               *"GNU coreutils"*)
                   CONFIG_STATUS="UNKNOWN"; CONFIG_UNKNOWN_CAUSE="toolchain"
                   TOOLCHAIN_MISSING="${TOOLCHAIN_MISSING:-GNU coreutils}" ;;
               *"mktemp failed"*)
                   # Both of the loader's mktemp deaths land here — the config snapshot's and
                   # yq_probe's. TMPDIR is at fault and config.yaml was never opened, so the
                   # `*)` below would answer INVALID and say a healthy file is malformed. This
                   # is the same cause the guarded mktemps at the top of this block already
                   # report for the probe's OWN temp files; the loader's are no different.
                   CONFIG_STATUS="UNKNOWN"; CONFIG_UNKNOWN_CAUSE="tmpfile" ;;
               *)  CONFIG_STATUS="INVALID" ;;
           esac ;;
    esac
    rm -f "$LERR"
fi
row config "$CONFIG_STATUS" "$CONFIG_DETAIL"

# ---------------------------------------------------------------- built-in claude
row builtin-claude OK "needs no config section (orchestrators still need config.yaml)"

CLAUDE_MODELS=""
GROK_MODELS=""
# A rejected catalog and an absent one both leave CLAUDE_MODELS empty, and the summary at the
# bottom has to tell them apart: "no catalog" means one claude reviewer on the dispatch model,
# "rejected" means the orchestrator exits on this very read and offers nothing at all.
CLAUDE_CATALOG_OK=1
if [ "$CONFIG_STATUS" = "OK" ]; then
    # CLAUDE_CATALOG_OK stays 1 deliberately: 0 means "both orchestrators exit on this read",
    # which is a claim about the section's CONTENTS, and its blocker says the section is
    # rejected. A temp file we could not create is no evidence for that accusation. The summary
    # then falls back to a bare `claude` — one reviewer on the dispatch model, the only claim
    # that needs no catalog — exactly as it does when there is no catalog at all.
    if ! CM_ERR="$(mktemp_or_fail)"; then
        row claude-models UNKNOWN "cannot create a temp file (TMPDIR full or unwritable) — catalog not read"
        CLAUDE_MODELS=""
    else
        CLAUDE_MODELS="$(bash "$LOADER" list-claude-models 2>"$CM_ERR")"; CM_RC=$?
        if [ "$CM_RC" -ne 0 ]; then
            # mesh-review Step 1 refuses to start on this same read — "no catalog" would be a lie.
            row claude-models INVALID "$(head -1 "$CM_ERR")"
            CLAUDE_MODELS=""
            CLAUDE_CATALOG_OK=0
        elif [ -n "$CLAUDE_MODELS" ]; then
            row claude-models OK "$(printf '%s' "$CLAUDE_MODELS" | tr '\n' ',' | sed 's/,$//; s/,/, /g')"
        else
            row claude-models MISSING "no claude.models catalog — one claude reviewer on the dispatch model"
        fi
        rm -f "$CM_ERR"
    fi
    HAS_CODEX="$(bash "$LOADER" get-flag has_codex 2>/dev/null)" || HAS_CODEX=0
    HAS_GEMINI="$(bash "$LOADER" get-flag has_gemini 2>/dev/null)" || HAS_GEMINI=0
    # `get-flag has_grok` VALIDATES the section before answering, unlike the bare has_codex and
    # has_gemini probes above — so a MALFORMED section makes it exit non-zero instead of
    # printing 0. Falling back to 0 there would report a config error as "the user never asked
    # for grok" and print MISSING; 1 means "section present, not valid", which lets the row
    # below reach its own get-grok probe and surface the validator's own first line — the same
    # way the claude-models row does.
    HAS_GROK="$(bash "$LOADER" get-flag has_grok 2>/dev/null)" || HAS_GROK=1
    # The catalog feeds the SUMMARY line, which must spell reviewer names exactly as the
    # orchestrators do: grok:grok-4.6, like claude:opus. A failed read leaves it empty and the
    # row below reports the section as INVALID through the typed getter.
    GROK_MODELS="$(bash "$LOADER" list-grok-models 2>/dev/null)" || GROK_MODELS=""
else
    row claude-models SKIPPED "no usable config"
fi

# ---------------------------------------------------------------- prerequisites
# TWO lookups, not one. CURL_BIN governs this script's own HTTP checks, but the borrowed
# prechecks resolve `curl` from PATH — so an override that resolves while PATH has no curl
# would let them run, and token-precheck.sh turns command-not-found into HTTP 000 (:43), i.e.
# a NO-NETWORK row fabricated out of a missing binary. Either gap skips the probes outright.
HAVE_CURL=1
CURL_GAP=""
command -v "$CURL_BIN" >/dev/null 2>&1 || CURL_GAP="$CURL_BIN"
if [ "$CURL_BIN" != curl ] && ! command -v curl >/dev/null 2>&1; then
    CURL_GAP="${CURL_GAP:+$CURL_GAP, }curl on PATH (where the prechecks look)"
fi
if [ -n "$CURL_GAP" ]; then
    HAVE_CURL=0
    row curl MISSING "not found: $CURL_GAP — own network probes and provider prechecks skipped, their rows read UNKNOWN"
fi

# ext-claude executors STOP without these (ext-claude-exec SKILL.md Dependencies); a reachable
# endpoint is useless if the executor cannot start. Unquoted on purpose: the list word-splits.
EXT_DEPS_MISSING=""
for T in $EXT_DEPS_BINS; do
    command -v "$T" >/dev/null 2>&1 || EXT_DEPS_MISSING="${EXT_DEPS_MISSING:+$EXT_DEPS_MISSING, }$T"
done
# python3 is NOT an ext-claude-only prerequisite: shared/extract-result.py is what grok-exec
# reads its own run with, and grok-exec STOPs without it — the only one of the three CLI engines
# that does (codex-exec and gemini-exec have no python3 gate at all). `bc` and `claude` are not
# in that class: grok-exec only WARNs about bc ("the review itself is unaffected") and never
# invokes the claude binary. So the row names grok exactly when python3 is the binary missing.
GROK_DEPS_MISSING=""
command -v python3 >/dev/null 2>&1 || GROK_DEPS_MISSING="python3"
if [ -n "$EXT_DEPS_MISSING" ]; then
    if [ -n "$GROK_DEPS_MISSING" ]; then
        row ext-claude-deps MISSING "$EXT_DEPS_MISSING — ext-claude executors cannot run here, and grok-exec STOPs without python3"
    else
        row ext-claude-deps MISSING "$EXT_DEPS_MISSING — ext-claude executors cannot run here"
    fi
fi

# ---------------------------------------------------------------- CLI reviewers
probe_http() {          # $1 = url; echoes OK | NO-NETWORK | UNKNOWN
    [ "$SKIP_NET" = 0 ] || { echo UNKNOWN; return 0; }
    [ "$HAVE_CURL" = 1 ] || { echo UNKNOWN; return 0; }
    local code
    code="$("$CURL_BIN" -sS -o /dev/null -w '%{http_code}' --max-time "$HTTP_TIMEOUT" "$1" 2>/dev/null)" \
        || code="000"
    # A three-digit code is the ONLY evidence of an answer. An `else echo OK` would turn a
    # curl that exits 0 printing nothing — a wrapper, a stub, a future --write-out change —
    # into a green verdict, which is the one direction this file never fabricates: every other
    # guard here (HAVE_CURL, the timeout(1) check below) degrades toward UNKNOWN instead.
    case "$code" in
        000)             echo NO-NETWORK ;;
        [0-9][0-9][0-9]) echo OK ;;
        *)               echo UNKNOWN ;;
    esac
}

# A CLI reviewer is offered by the selection UI only when its config section exists
# (mesh-review Step 2 / mesh-design-review Step 5.2) — but its consumers then read the section
# through the TYPED getter (get-codex / get-gemini), which validates and dies on a malformed
# one, while the bare has_* probe validates nothing. Mirror both gates, section first: a codex
# binary with no codex: section is not a reviewer you can pick, however healthy its network is;
# a section the getter rejects is INVALID before any CLI or network claim.
# cli_row prints its row and reports the verdict through the CLI_STATUS global. It must NOT
# echo the verdict: the caller would have to capture its stdout, and the row would vanish into
# that same capture instead of reaching the report.
CLI_STATUS=""
cli_row() {             # $1 = name, $2 = binary, $3 = probe url, $4 = has_section flag, $5 = probe command (optional)
                        # $6 = file to keep the probe's stdout in (optional, only with $5)
                        # $5 is deliberately UNQUOTED where it is EXPANDED — the `timeout` line
                        # inside the probe branch below, not the cli_row call site, which quotes
                        # it like any other argument. It must split into argv there
                        # ("grok models" -> two words). That makes word splitting part of this
                        # function's public contract, so a caller may never pass a value
                        # carrying spaces-in-one-argument, and glob characters must be disabled
                        # around the expansion (`set -f` / `set +f`) or a probe like `foo *`
                        # would expand against the cwd.
    if [ "$CONFIG_STATUS" != "OK" ]; then
        CLI_STATUS="SKIPPED"
        row "$1" SKIPPED "no usable config — the selection UI cannot offer it"
        return 0
    fi
    if [ "$4" != "1" ]; then
        CLI_STATUS="MISSING"
        row "$1" MISSING "no $1: section in config — the selection UI will not offer it"
        return 0
    fi
    local gerr
    # Checked, because the failure is silent and ugly: gerr="" makes `2>"$gerr"` an ambiguous
    # redirect, which fails the command, which makes the branch below look like a REJECTED
    # section — and then `head -1 ""` prints its own complaint on the probe's stderr. A full
    # TMPDIR must not be reported as a malformed config. (This site is where the guard was
    # written first; mktemp_or_fail is that check, hoisted so the other four cannot skip it.)
    if ! gerr="$(mktemp_or_fail)"; then
        CLI_STATUS="UNKNOWN"
        row "$1" UNKNOWN "cannot create a temp file (TMPDIR full or unwritable) — section not validated"
        return 0
    fi
    if ! bash "$LOADER" "get-$1" >/dev/null 2>"$gerr"; then
        CLI_STATUS="INVALID"
        row "$1" INVALID "$(head -1 "$gerr")"
        rm -f "$gerr"
        return 0
    fi
    rm -f "$gerr"
    if ! command -v "$2" >/dev/null 2>&1; then
        CLI_STATUS="MISSING"
        row "$1" MISSING "$2 not on PATH"
        return 0
    fi
    # An OPTIONAL command probe replaces the HTTP one for a CLI whose reachability an HTTP
    # request cannot answer. grok is the case: on a grok.com subscription the traffic goes
    # through a relay, not through the public api.x.ai, so a curl there would report on an
    # endpoint this CLI never calls — while `grok models` answers only with network AND a live
    # login, and prints nothing secret. Same degrade-toward-UNKNOWN discipline as probe_http:
    # the flag skips it, and only a clean exit is allowed to mean OK.
    if [ -n "${5:-}" ]; then
        if [ "$SKIP_NET" = 1 ]; then
            CLI_STATUS="UNKNOWN"
            row "$1" UNKNOWN "CLI present, skipped by PREFLIGHT_SKIP_NETWORK"
        elif ! command -v timeout >/dev/null 2>&1; then
            CLI_STATUS="UNKNOWN"
            row "$1" UNKNOWN "CLI present, no timeout(1) — \`$5\` not run (brew install coreutils)"
        else
            local rc
            echo "probing $1 (\`$5\`)…" >&2
            set -f                                   # see the contract note on $5 above
            # shellcheck disable=SC2086
            # $6 keeps the probe's stdout so a caller does not have to run the same command
            # a second time for its output. Without it the grok CLI was invoked twice per
            # preflight — health probe, then listing — costing two authenticated round-trips
            # and up to 2x CLI_TIMEOUT, and leaving two rows that describe ONE fact from two
            # separate observations, free to disagree if a login expires between them.
            timeout "$CLI_TIMEOUT" $5 >"${6:-/dev/null}" 2>/dev/null; rc=$?
            set +f                                   # restored on BOTH paths, before any branch
            if [ "$rc" -eq 0 ]; then
                CLI_STATUS="OK"
                row "$1" OK "CLI present, \`$5\` answered (checks login as well as network)"
            else
                CLI_STATUS="NO-NETWORK"
                row "$1" NO-NETWORK "CLI present, \`$5\` failed or timed out after ${CLI_TIMEOUT}s — no network, not logged in (\`$2 login\`), or slower than the budget (raise PREFLIGHT_CLI_TIMEOUT)"
            fi
        fi
        return 0
    fi
    # Announce only a probe that will actually happen — same order as the provider loop below.
    # "probing codex…" followed by an UNKNOWN row would describe work the probe never did.
    if [ "$SKIP_NET" = 0 ] && [ "$HAVE_CURL" = 1 ]; then
        echo "probing $1 ($3)…" >&2
    fi
    CLI_STATUS="$(probe_http "$3")"
    case "$CLI_STATUS" in
        OK)         row "$1" OK         "CLI present, $3 answered (heuristic: not an auth check)" ;;
        NO-NETWORK) row "$1" NO-NETWORK "CLI present, $3 silent for ${HTTP_TIMEOUT}s (heuristic)" ;;
        # Two different facts, and the plan pins the wording of one of them: a row skipped by the
        # flag must read `skipped by PREFLIGHT_SKIP_NETWORK`, exactly as the provider rows do.
        # Conflating it with "no curl" also loses the actionable half — one is a deliberate
        # choice this run made, the other is a missing binary.
        *)          if [ "$SKIP_NET" = 1 ]; then
                        row "$1" UNKNOWN "CLI present, skipped by PREFLIGHT_SKIP_NETWORK"
                    else
                        row "$1" UNKNOWN "CLI present, network not probed (no curl)"
                    fi ;;
    esac
}

cli_row codex  "codex"  "https://api.openai.com/v1/models"           "$HAS_CODEX";  CODEX_STATUS="$CLI_STATUS"
cli_row gemini "gemini" "https://generativelanguage.googleapis.com/" "$HAS_GEMINI"; GEMINI_STATUS="$CLI_STATUS"
# The URL argument is unused when a command probe is given; pass the CLI's own docs host so the
# row's shape stays uniform and a future reader can see what an HTTP fallback would target.
GROK_LISTING=""
GROK_LISTING="$(mktemp_or_fail 2>/dev/null || true)"
cli_row grok   "grok"   "https://api.x.ai/v1/models"                 "$HAS_GROK" "grok models" "$GROK_LISTING"; GROK_STATUS="$CLI_STATUS"

# native-models: listing only. Never infer we are inside Grok Build.
# Reuses the grok row's probe output whenever that probe actually ran. `grok models` is a
# network+login round-trip; calling it twice cost two authenticated calls and up to 2x
# CLI_TIMEOUT, and — the part that misleads rather than merely costs — made these two rows two
# independent observations of ONE fact, free to disagree when a login expires between them.
#
# It does NOT simply follow GROK_STATUS. `native` and the `grok:` config section are separate
# things by design: native_models needs no grok: section at all (it is charset-validated on its
# own). So when the grok row returned WITHOUT probing for a config reason — no section, or an
# invalid one — this must still list the host's slugs itself. Only a probe that ran and failed
# (NO-NETWORK) or was suppressed (UNKNOWN: SKIP_NET / no timeout) means "do not ask again".
NM_STATUS=SKIP
NM_LIST=""
_nm_from_listing() {        # $1 = file holding `grok models` output
    NM_LIST=$(bash "$SCRIPT_DIR/list-host-models.sh" --from-file "$1" | tr '\n' ' ')
    NM_LIST=${NM_LIST%% }
    if [ -n "${NM_LIST// }" ]; then
        NM_STATUS=OK
        NM_DETAIL="$NM_LIST"
    else
        # Parsed zero slugs: not selectable. OK + empty used to advertise a bare
        # `native` in SUMMARY while runtime degraded HOST_MODELS="".
        NM_STATUS=SKIP
        NM_DETAIL="empty listing"
        NM_LIST=""
    fi
}
case "$GROK_STATUS" in
    OK)
        if [ -n "$GROK_LISTING" ] && [ -s "$GROK_LISTING" ]; then
            _nm_from_listing "$GROK_LISTING"
        else
            NM_DETAIL="grok models answered but its output was not captured"
        fi ;;
    UNKNOWN)    NM_DETAIL="grok models not run — see the grok row" ;;
    NO-NETWORK) NM_DETAIL="grok models failed or timed out — see the grok row" ;;
    *)
        # MISSING / INVALID / SKIPPED: the grok ROW is about the grok: section, not about
        # native. Probe here, under the same discipline the row uses — nothing may take it down.
        if ! command -v grok >/dev/null 2>&1; then
            NM_DETAIL="no grok CLI on PATH — nothing to list"
        elif [ "$SKIP_NET" = 1 ]; then
            NM_DETAIL="skipped by PREFLIGHT_SKIP_NETWORK"
        elif ! command -v timeout >/dev/null 2>&1; then
            NM_DETAIL="no timeout(1) — grok models not run (brew install coreutils)"
        else
            _GM=""
            if ! _GM="$(mktemp_or_fail)"; then
                NM_DETAIL="cannot create a temp file — grok models not run"
            else
                if timeout "${CLI_TIMEOUT}" grok models >"$_GM" 2>/dev/null; then
                    _nm_from_listing "$_GM"
                else
                    NM_DETAIL="grok models failed or timed out"
                fi
                rm -f "$_GM"
            fi
        fi ;;
esac
[ -z "$GROK_LISTING" ] || rm -f "$GROK_LISTING"
row native-models "$NM_STATUS" "$NM_DETAIL"

CLAUDE_CLI_STATUS=OK
if command -v claude >/dev/null 2>&1; then
    row claude-cli OK "claude on PATH"
else
    CLAUDE_CLI_STATUS=MISSING
    row claude-cli MISSING "claude CLI not on PATH"
fi

# ---------------------------------------------------------------- providers
# Models of one provider share an endpoint, so probe once per provider and let Task 4 expand
# the verdict back into model ids. Rows appear in order of first appearance in `models`; a
# provider with no models gets no row — nothing it could offer the selection UI.
declare -A PROBED_STATUS=()

# Verdict comes back through globals and probe_provider is called as its own command — NEVER
# inside $(...): an assignment made in a command substitution dies with its subshell, and
# CURRENT_ENVF is what the EXIT trap deletes. cli_row (Task 3) follows the same rule for the
# same reason.
PROV_STATUS=""
PROV_DETAIL=""
probe_provider() {      # $1 = a model id of the provider; sets PROV_STATUS / PROV_DETAIL
    local mid="$1" eerr first out rc rest kind url
    # Unlike the sites above, the verdict here was already honest without the guard — export
    # would fail on the redirect and land in the UNKNOWN arm below. What the check buys is the
    # stderr: three raw mktemp/head diagnostics on the stream the suite gates on, from a probe
    # whose stdout is meant to be the whole report.
    if ! eerr="$(mktemp_or_fail)"; then
        PROV_STATUS="UNKNOWN"
        PROV_DETAIL="cannot create a temp file (TMPDIR full or unwritable) — endpoint not probed"
        return 0
    fi
    # The destination is created and named HERE, before export runs. Assigned STRAIGHT into the
    # global, never into a local first: from this line on the trap already covers anything the
    # loader creates inside it, which is what the old file-name-only approach could not do —
    # the name did not exist until the command substitution returned.
    if ! CURRENT_ENVD="$(mktemp_dir_or_fail)"; then
        rm -f "$eerr"
        PROV_STATUS="UNKNOWN"
        PROV_DETAIL="cannot create a temp dir (TMPDIR full or unwritable) — endpoint not probed"
        return 0
    fi
    # TMPDIR is how the destination is imposed without touching the loader's contract: its
    # `mktemp -t` honours it, so the mode-600 token file lands inside the directory the trap
    # holds. If a future loader ever stopped honouring TMPDIR the interrupt scenario in
    # test-preflight-env.sh fails, which is the point of pinning it there.
    if ! CURRENT_ENVF="$(TMPDIR="$CURRENT_ENVD" bash "$LOADER" export "$mid" 2>"$eerr")"; then
        first="$(head -1 "$eerr")"; rm -f "$eerr"
        # export prints the path only on success, so this is normally empty. If a future
        # loader ever printed one and then died, leave it set so the trap deletes the file.
        [ -n "$CURRENT_ENVF" ] && [ -f "$CURRENT_ENVF" ] || CURRENT_ENVF=""
        # cmd_export also dies on invalid providers/models/runtime and "model not found" —
        # only a token complaint may be blamed on the token.
        case "$first" in
            *REPLACE_ME*|*[Tt]oken*) PROV_STATUS="MISSING"; PROV_DETAIL="token not configured for this provider (export refused)" ;;
            *)                       PROV_STATUS="UNKNOWN"; PROV_DETAIL="export refused: ${first:-no reason printed}" ;;
        esac
        # Whatever the dead loader may have left inside goes with the directory.
        rm -rf "$CURRENT_ENVD" && CURRENT_ENVD=""
        return 0
    fi
    rm -f "$eerr"
    if [ -z "$CURRENT_ENVF" ] || [ ! -f "$CURRENT_ENVF" ]; then
        CURRENT_ENVF=""
        rm -rf "$CURRENT_ENVD" && CURRENT_ENVD=""
        PROV_STATUS="UNKNOWN"; PROV_DETAIL="export produced no env file"; return 0
    fi
    # Subshell: the token lives only here; only "rc|kind|base_url" leaves it. base_url is not
    # a secret (the token is a separate field) and it is the first thing the operator wants;
    # kind decides how to word an rc=5. Both prechecks print their diagnosis on stderr, which
    # is discarded — dropping that 2>&1 would put up to 400 bytes of raw provider response on
    # the probe's own stderr (token-precheck.sh:49), which the suite's stderr gate rejects.
    out="$(
        # FIRST statement, before the token is sourced: with xtrace on (SHELLOPTS=xtrace in the
        # environment, or `bash -x`) every expansion below is echoed to stderr, and that put
        # `export ANTHROPIC_AUTH_TOKEN=<token>` on the very stream config-loader.sh:727 uses a
        # mode-600 tmpfile to stay out of. "No secret ever reaches stdout or stderr" has no
        # clause about how the operator started the probe.
        set +x
        # shellcheck disable=SC1090
        . "$CURRENT_ENVF"
        # :- guards: a truncated env file must degrade to a verdict, not abort the subshell
        # under `set -u` and print bash's own diagnostic on stderr.
        KIND="${CLAUDE_MESH_PROVIDER_KIND:-anthropic-api}"
        case "$KIND" in
            ollama-daemon)
                env -u SKIP_TOKEN_PRECHECK \
                    OLLAMA_PRECHECK_TRIES=1 \
                    OLLAMA_PRECHECK_ATTEMPT_TIMEOUT="$HTTP_TIMEOUT" \
                    OLLAMA_PRECHECK_TAGS_TIMEOUT="$HTTP_TIMEOUT" \
                    bash "$EXEC_DIR/ollama-precheck.sh" "${ANTHROPIC_BASE_URL:-}" >/dev/null 2>&1
                printf '%s|%s|%s' "$?" "$KIND" "${ANTHROPIC_BASE_URL:-}" ;;
            *)
                env -u SKIP_TOKEN_PRECHECK bash "$EXEC_DIR/token-precheck.sh" \
                    "${ANTHROPIC_BASE_URL:-}" "${ANTHROPIC_AUTH_TOKEN:-}" "$HTTP_TIMEOUT" >/dev/null 2>&1
                printf '%s|%s|%s' "$?" "$KIND" "${ANTHROPIC_BASE_URL:-}" ;;
        esac
    )"
    # Cleared only once the unlink actually succeeded: otherwise the trap must keep the name
    # so it can try again at exit. Same rule for the directory.
    rm -f "$CURRENT_ENVF" && CURRENT_ENVF=""
    rm -rf "$CURRENT_ENVD" && CURRENT_ENVD=""
    # url takes everything after the SECOND separator, so a '|' inside a base_url survives.
    rc="${out%%|*}"; rest="${out#*|}"; kind="${rest%%|*}"; url="${rest#*|}"
    case "$rc" in
        0) PROV_STATUS="OK";          PROV_DETAIL="endpoint answered, credentials accepted ($url)" ;;
        5) PROV_STATUS="AUTH-FAILED"
           # An ollama daemon has no credential to reject — rc=5 there means the daemon is up
           # but /api/tags errored. "credentials rejected" would send the operator hunting for
           # a token that does not exist.
           if [ "$kind" = "ollama-daemon" ]; then
               PROV_DETAIL="daemon up but /api/tags errored — run: ollama signin ($url)"
           else
               PROV_DETAIL="endpoint answered, credentials rejected ($url)"
           fi ;;
        6) PROV_STATUS="NO-NETWORK";  PROV_DETAIL="$url did not answer within ${HTTP_TIMEOUT}s" ;;
        *) PROV_STATUS="UNKNOWN";     PROV_DETAIL="precheck exited $rc ($url)" ;;
    esac
}

if [ "$CONFIG_STATUS" != "OK" ]; then
    row provider SKIPPED "no usable config — providers not probed"
elif [ -z "$MODELS" ]; then
    row provider MISSING "config has no models"
else
    while IFS='|' read -r MID _LABEL; do
        [ -n "$MID" ] || continue
        PROV="${MID%%/*}"
        [ -z "${PROBED_STATUS[$PROV]+x}" ] || continue
        if [ -n "$EXT_DEPS_MISSING" ]; then
            PROBED_STATUS[$PROV]="MISSING"
            row "provider:$PROV" MISSING "ext-claude prerequisites absent: $EXT_DEPS_MISSING"
            continue
        fi
        if [ "$HAVE_CURL" = 0 ]; then
            PROBED_STATUS[$PROV]="UNKNOWN"
            row "provider:$PROV" UNKNOWN "no curl — endpoint not probed"
            continue
        fi
        if [ "$SKIP_NET" = 1 ]; then
            PROBED_STATUS[$PROV]="UNKNOWN"
            row "provider:$PROV" UNKNOWN "skipped by PREFLIGHT_SKIP_NETWORK"
            continue
        fi
        echo "probing $PROV…" >&2
        probe_provider "$MID"
        row "provider:$PROV" "$PROV_STATUS" "$PROV_DETAIL"
        PROBED_STATUS[$PROV]="$PROV_STATUS"
    done <<< "$MODELS"
fi

# --------------------------------------------------------------------------- git, forge CLIs
# git remote — local refs are enough for the review skills; this row exists so the reading
# session does not plan a push it cannot make. GIT_TERMINAL_PROMPT=0 + BatchMode: a remote
# that wants credentials or host-key confirmation must answer instantly instead of stalling
# into the timeout and being miscalled NO-NETWORK.
if ! command -v "$GIT_BIN" >/dev/null 2>&1; then
    row git-remote MISSING "$GIT_BIN not on PATH"
elif ! "$GIT_BIN" rev-parse --git-dir >/dev/null 2>&1; then
    row git-remote MISSING "not inside a git repository"
elif ! "$GIT_BIN" remote get-url origin >/dev/null 2>&1; then
    row git-remote MISSING "no 'origin' remote configured"
elif [ "$SKIP_NET" = 1 ]; then
    row git-remote UNKNOWN "skipped by PREFLIGHT_SKIP_NETWORK"
elif ! command -v timeout >/dev/null 2>&1; then
    # timeout(1) is GNU-only and absent on a stock macOS — precisely the unconfigured machine
    # this probe exists for (config-loader.sh:76 fails for the same reason). Without this
    # branch the command-not-found would fail the `if` below and print NO-NETWORK: an endpoint
    # verdict invented out of a missing binary, the same defect the curl gate above prevents.
    row git-remote UNKNOWN "no timeout(1) — ls-remote not run (brew install coreutils)"
else
    if GIT_TERMINAL_PROMPT=0 GIT_SSH_COMMAND='ssh -oBatchMode=yes' \
       timeout "$GIT_TIMEOUT" "$GIT_BIN" ls-remote --exit-code origin HEAD >/dev/null 2>&1; then
        row git-remote OK "origin answered"
    else
        row git-remote NO-NETWORK "origin did not answer (or refused) within ${GIT_TIMEOUT}s — do not plan a push or a PR"
    fi
fi

for TOOL in gh glab; do
    if command -v "$TOOL" >/dev/null 2>&1; then
        row "$TOOL" OK "on PATH (presence only — not an auth check)"
    else
        row "$TOOL" MISSING "not on PATH"
    fi
done

# ------------------------------------------- Bash tool timeout ceiling (Claude Code, not config)
# Last of the environment rows, and an environment row it is: these two variables are Claude
# Code's, not the plugin's, and live in settings.json rather than config.yaml.
#
# The harness caps a FOREGROUND Bash call at the LARGER of BASH_MAX_TIMEOUT_MS and
# BASH_DEFAULT_TIMEOUT_MS and SIGTERMs it at the cap, taking the whole process group with it —
# the shape verify-delegation.sh reports as KILLED. Below `runtime.timeouts.global_sec` the
# plugin's own budgets are unreachable by construction, which is the invariant README states.
#
# LOW, not MISSING: the stock values are perfectly valid Claude Code settings, just too small
# for these budgets. And not a blocker: the exec skills launch their engine as a background
# task, where the cap does not apply. What this row buys is the machine that never set them — a
# wrapper ignoring the background rule dies at 600s there, and so does any long FOREGROUND
# command the session runs by hand (this repo's own test suite takes ~3 minutes). Naming the
# number beforehand beats diagnosing a KILLED afterwards.
if [ "$CONFIG_STATUS" = "OK" ]; then
    GLOBAL_SEC="$(bash "$LOADER" get-runtime 2>/dev/null | "$JQ_BIN" -r '.timeouts.global_sec // empty' 2>/dev/null)"
    # Every value here is range-checked before it reaches `[ -ge ]`: a non-numeric one would make
    # `[` fail, and with its error swallowed the row would silently vanish from the table. An
    # unset or unusable value is read as the default the harness itself would apply.
    case "$GLOBAL_SEC" in ''|*[!0-9]*) GLOBAL_SEC=3600 ;; esac
    BASH_CAP_MS="${BASH_MAX_TIMEOUT_MS:-600000}"
    BASH_DEF_MS="${BASH_DEFAULT_TIMEOUT_MS:-120000}"
    case "$BASH_CAP_MS" in ''|*[!0-9]*) BASH_CAP_MS=600000 ;; esac
    case "$BASH_DEF_MS" in ''|*[!0-9]*) BASH_DEF_MS=120000 ;; esac
    BASH_EFF_MS="$BASH_CAP_MS"
    [ "$BASH_DEF_MS" -le "$BASH_EFF_MS" ] || BASH_EFF_MS="$BASH_DEF_MS"
    BASH_NEED_MS=$(( GLOBAL_SEC * 1000 ))
    if [ "$BASH_EFF_MS" -ge "$BASH_NEED_MS" ]; then
        row bash-timeout OK "foreground ceiling ${BASH_EFF_MS}ms >= runtime.timeouts.global_sec (${GLOBAL_SEC}s)"
    else
        row bash-timeout LOW "foreground ceiling ${BASH_EFF_MS}ms < global_sec ${GLOBAL_SEC}s — a foreground run is SIGTERMed there; set \"BASH_MAX_TIMEOUT_MS=${BASH_NEED_MS}\" in the env block of ~/.claude/settings.json (background launches are unaffected)"
    fi
else
    row bash-timeout SKIPPED "no usable config — runtime.timeouts.global_sec unknown"
fi

# ---------------------------------------------------------------- summary
# The two lines the reading session actually acts on. Names are spelled exactly as the
# selection UI of /mesh-review and /mesh-design-review spells them, so nothing has to be
# mapped: `claude:opus`-style entries per catalog model (plain `claude` only in the
# no-catalog fallback — the confirmation page uses the same spelling), `codex`, `gemini`,
# and model ids like `zai/glm`.
AVAIL=""
UNAVAIL=""

# TWO reads decide whether the orchestrators ever REACH their selection step, and neither of
# them belongs to a single reviewer: config.yaml (mesh-review Step 0/1, mesh-design-review
# Step 5.0) and the claude: catalog (both orchestrators `|| exit 1` on the same
# list-claude-models read in their Step 1 / Step 5.0 fence — cited by the read, not by a line
# number, because the number has already gone stale once
# the claude-models row reports above). Either one exits BEFORE anything is offered, so either
# one makes EVERY reviewer unselectable — including a provider whose endpoint just answered.
# Offering one here sends the reading session into a dead end it cannot debug from the table.
#
# The hint below is a LITERALLY EXECUTABLE command, so it must branch on WHICH state produced
# the block — `CONFIG_STATUS != OK` covers three of them and `cp config.example.yaml …` is
# right in only one. For INVALID and UNKNOWN a real config.yaml exists (in the UNKNOWN case
# possibly a perfectly good one, on a machine that merely lacks yq) and that command overwrites
# it, tokens and all. config.yaml is user-owned and agents never edit it (mesh-review/commands/mesh-review.md,
# Step 1), so a table the generated prompts tell a session to print verbatim must not carry an
# instruction to clobber it. It is also the distinction Task 1's config row exists to draw:
# "install a usable yq" and "edit a healthy config" are different days' work.
BLOCKER=""
BLOCKER_HINT=""
CONFIG_PATH="<config-path>"
if [ "$CONFIG_STATUS" != "OK" ] || [ "$CLAUDE_CATALOG_OK" = 0 ]; then
    # Only a blocked run needs a path, and only a blocked run pays for the extra loader start.
    # Guarded because config-path prints nothing when the loader is absent, and a hint whose
    # path is empty points at a file nobody has.
    CP="$(bash "$LOADER" config-path 2>/dev/null)"
    [ -z "$CP" ] || CONFIG_PATH="$CP"
fi
case "$CONFIG_STATUS" in
    OK) ;;
    MISSING)
        BLOCKER="config.yaml required for the orchestrators to start"
        # Which MISSING decides the advice, and one of the two answers is actively wrong for the
        # other case: copying a config into place does nothing about a loader that is not there.
        case "$CONFIG_MISSING_CAUSE" in
            install)
                BLOCKER="mesh-exec install is incomplete"
                BLOCKER_HINT="reinstall or update the mesh-exec plugin — config-loader.sh is missing from $PLUGIN_ROOT/skills/shared; no config.yaml can fix that" ;;
            *)
                # The loader found the claude-mesh config in its old home: the fix is to move
                # that file, not to start a blank one, and the command is the loader's, verbatim.
                if [ -n "$CONFIG_OLD_PATH" ] && [ -n "$CONFIG_MOVE_CMD" ]; then
                    BLOCKER_HINT="the claude-mesh config is still at $CONFIG_OLD_PATH — move it: $CONFIG_MOVE_CMD"
                else
                    # dirname, and no cd before the cp: MESH_CONFIG may be a relative path.
                    BLOCKER_HINT="mkdir -p \"$(dirname -- "$CONFIG_PATH")\" && cp \"$PLUGIN_ROOT/config.example.yaml\" \"$CONFIG_PATH\" && chmod 600 \"$CONFIG_PATH\" — the review skills need it even for the built-in claude reviewer"
                fi ;;
        esac ;;
    INVALID)
        BLOCKER="config.yaml is rejected — see the config row"
        BLOCKER_HINT="edit $CONFIG_PATH to fix what the config row reports — do NOT overwrite it with config.example.yaml: it is user-owned and holds your provider tokens" ;;
    UNKNOWN)
        # UNKNOWN: the loader never ran, so nothing above is a statement about the file's
        # contents. MORE THAN ONE cause reaches here and their fixes have nothing in common —
        # an operator whose TMPDIR is unwritable must not be sent to install yq, and this arm
        # used to be spelled `*)` and say exactly that to both. Branch on the cause recorded
        # where the verdict was made, never re-derive it here: a third cause that forgets to
        # set it must fall through to "read the row", not inherit whichever advice is last.
        BLOCKER="config state could not be evaluated"
        U_FIX=""
        case "$CONFIG_UNKNOWN_CAUSE" in
            toolchain)
                # Naming what to install matters more than usual here: both flavors are
                # accepted, so the advice has to name both rather than send half the readers
                # to the wrong binary.
                T_FIX=""
                case "$TOOLCHAIN_MISSING" in *yq*) T_FIX="install a yq that emits JSON — 'pipx install yq' (Python-yq) or 'apt install yq' / 'brew install yq' (Go-yq v4+)" ;; esac
                case "$TOOLCHAIN_MISSING" in *jq*) T_FIX="${T_FIX:+$T_FIX; }apt install jq (or brew install jq)" ;; esac
                U_FIX="install the loader toolchain — ${T_FIX:-see README Dependencies}" ;;
            tmpfile)
                U_FIX="make TMPDIR writable, free space on it, or point TMPDIR at a directory that has both" ;;
            *)
                U_FIX="fix what the config row above reports" ;;
        esac
        BLOCKER_HINT="$U_FIX — then re-run; $CONFIG_PATH was never read, so nothing above says anything about its contents" ;;
    *)
        # Defence in depth: every member of the closed status set is spelled out above, so this
        # arm is unreachable today. It exists because the alternative to an unreachable arm is a
        # silent one — a status added later would leave BLOCKER empty and the summary would
        # cheerfully offer reviewers the orchestrator never reaches.
        BLOCKER="config state is not usable ($CONFIG_STATUS)"
        BLOCKER_HINT="see the config row above — this probe has no advice for that state" ;;
esac
if [ -z "$BLOCKER" ] && [ "$CLAUDE_CATALOG_OK" = 0 ]; then
    BLOCKER="the claude: section is rejected and both orchestrators exit on that read"
    BLOCKER_HINT="fix the claude: section of $CONFIG_PATH (the claude-models row above carries the validator's reason) — both orchestrators exit on that read before offering anything"
fi

add_unavail() { if [ -z "$UNAVAIL" ]; then UNAVAIL="$1"; else UNAVAIL="$UNAVAIL, $1"; fi; }
add_avail() {
    # One switch instead of one test per reviewer type: while a blocker stands nothing is
    # selectable, whatever the individual rows say. Redirecting HERE rather than at each call
    # site means a reviewer type added to this section later cannot forget the gate.
    if [ -n "$BLOCKER" ]; then add_unavail "$1 (blocked)"; return 0; fi
    if [ -z "$AVAIL" ]; then AVAIL="$1"; else AVAIL="$AVAIL, $1"; fi
}

# claude is unconditionally available as a REVIEWER — it needs no config section of its own —
# but see BLOCKER above: promising it in an environment where the orchestrator exits before the
# selection UI is the one thing this line must never do. The one-line fix is hinted at the end.
if [ -z "$BLOCKER" ]; then
    if [ -n "$CLAUDE_MODELS" ]; then
        while IFS= read -r CM; do
            [ -n "$CM" ] && add_avail "claude:$CM"
        done <<< "$CLAUDE_MODELS"
    else
        add_avail claude
    fi
else
    add_unavail "claude ($BLOCKER)"
fi

# if/else, not `A && add_avail || add_unavail`: in that form C also runs when B fails, so the
# day add_avail grows a non-zero path a reviewer gets listed on BOTH lines. Same reason cli_row
# spells out its progress gate rather than chaining it (SC2015).
if [ "$CODEX_STATUS"  = "OK" ]; then add_avail codex;  else add_unavail "codex ($CODEX_STATUS)";   fi
if [ "$GEMINI_STATUS" = "OK" ]; then add_avail gemini; else add_unavail "gemini ($GEMINI_STATUS)"; fi
# `SUMMARY available` is what commands/*-fresh-session.md call the eligibility decision in so
# many words, and `default` is non-interactive, so nobody is there to cross-read three rows and
# infer that a grok reviewer will die. The design declines to cross-check availability against
# the SUBSCRIPTION, for a stated reason that does not reach here: it would mean parsing the
# human-readable output of `grok models`. `command -v python3` needs no parsing.
if [ "$GROK_STATUS" = "OK" ] && [ -n "$GROK_DEPS_MISSING" ]; then
    add_unavail "grok (python3 missing — grok-exec STOPs on shared/extract-result.py)"
elif [ "$GROK_STATUS" = "OK" ]; then
    # One entry per catalog model, exactly as claude expands over claude.models above. The bare
    # `grok` fallback cannot normally happen — the validator requires a non-empty catalog
    # whenever the section exists — but a reader is better served by a name than by silence if
    # some future config shape reaches here with an empty list.
    if [ -n "$GROK_MODELS" ]; then
        while IFS= read -r GM; do
            [ -n "$GM" ] && add_avail "grok:$GM"
        done <<< "$GROK_MODELS"
    else
        add_avail grok
    fi
else
    add_unavail "grok ($GROK_STATUS)"
fi

# Host slugs from a successful `grok models` listing. Not added when the listing
# was SKIP/empty: SUMMARY names what can be selected, and a SKIP row is not that.
#
# The bare `native` below is the same fallback claude and grok already carry above, and it
# closes the same hole for the same reason: a preset with `native` in builtin and an EMPTY
# native_models is valid — that is the documented session-model fallback — and the defaults
# line then prints a bare `native`. Without this, available holds only `native:<slug>` and
# never the bare name, so a perfectly working Grok host reads as "default mode unsafe".
if [ "$NM_STATUS" = "OK" ]; then
    if [ -n "$NM_LIST" ]; then
        for NM_SLUG in $NM_LIST; do
            [ -n "$NM_SLUG" ] && add_avail "native:$NM_SLUG"
        done
    fi
    add_avail native
fi

if [ -n "$MODELS" ]; then
    while IFS='|' read -r MID _LABEL; do
        [ -n "$MID" ] || continue
        PROV="${MID%%/*}"
        PSTATUS="${PROBED_STATUS[$PROV]:-UNKNOWN}"
        if [ "$PSTATUS" = "OK" ]; then add_avail "$MID"; else add_unavail "$MID ($PSTATUS)"; fi
    done <<< "$MODELS"
fi

echo
printf 'SUMMARY available: %s\n' "${AVAIL:-—}"
printf 'SUMMARY unavailable: %s\n' "${UNAVAIL:-—}"
# PREFLIGHT_SKIP_NETWORK turns every network verdict into UNKNOWN, and UNKNOWN is not a
# degraded OK: on a fast re-run a perfectly working machine reports as "claude only". The
# reading session did not set that flag and cannot see it from the table, so the summary says
# so itself. SUMMARY-prefixed like the lines above — that is what the report's non-row prose
# is prefixed with, and what the suite's closed-set gate skips.
#
# Gated on an (UNKNOWN) actually having been printed, not on the flag alone: with no usable
# config every entry reads (SKIPPED) and there is no network verdict to qualify, so the note
# would point at a marker that is not on the page.
SAW_UNKNOWN=0
case "$UNAVAIL" in *"(UNKNOWN)"*) SAW_UNKNOWN=1 ;; esac
if [ "$SKIP_NET" = 1 ] && [ "$SAW_UNKNOWN" = 1 ]; then
    printf 'SUMMARY note: PREFLIGHT_SKIP_NETWORK was set, so nothing was probed — every (UNKNOWN) above is unestablished, not broken; re-run without it before concluding a reviewer is unusable\n'
fi
# The presets, in the same UI spelling — "default mode is safe here" becomes a mechanical
# check: every name on a defaults line must appear in SUMMARY available. jq is present
# whenever CONFIG_STATUS=OK (the toolchain gate ran first).
for PRESET in design_review code_review; do
    DLIST="—"
    DJ=""
    if [ "$CONFIG_STATUS" = "OK" ] && DJ="$(bash "$LOADER" get-defaults "$PRESET" 2>/dev/null)"; then
        # grok and native are expanded over their *_models lists exactly as claude is over
        # claude_models, and for the same reason: SUMMARY available spells those reviewers
        # grok:<model> / native:<slug>, so a leftover-builtin `native` (or `grok`) here would
        # print two different names for one reviewer and break the membership check this line
        # exists for. Empty native_models is valid (session-model fallback) and stays a bare
        # `native`. The validator guarantees a non-empty grok_models whenever `grok` is in
        # builtin, so that expansion is always defined.
        DLIST="$("$JQ_BIN" -r '
            ((.builtin // []) | map(select(. != "claude" and . != "grok" and . != "native"))) +
            (if ((.builtin // []) | index("claude")) then
                 (if ((.claude_models // []) | length) > 0
                  then (.claude_models | map("claude:" + .))
                  else ["claude"] end)
             else [] end) +
            (if ((.builtin // []) | index("grok")) then
                 (if ((.grok_models // []) | length) > 0
                  then (.grok_models | map("grok:" + .))
                  else ["grok"] end)
             else [] end) +
            (if ((.builtin // []) | index("native")) then
                 (if ((.native_models // []) | length) > 0
                  then (.native_models | map("native:" + .))
                  else ["native"] end)
             else [] end) +
            (.models // []) | join(", ")' <<<"$DJ")"
        # "—" alone would be read as "not answered", which is what the no-config case above
        # means. A preset that WAS read and is empty is a different fact: `default` mode will
        # refuse to start (mesh-design-review Step 5.1), and the fix is to write the preset.
        [ -n "$DLIST" ] || DLIST="— (preset empty)"
    fi
    printf 'SUMMARY defaults %s: %s\n' "$PRESET" "$DLIST"
    # From the preset JSON, not from the rendered DLIST: `*native*` on the joined string also
    # matched a model id that merely contains the word (`zai/alternative`), and the note below
    # is about the `native` TYPE being in `builtin`.
    if [ -n "${DJ:-}" ] && jq -e '((.builtin // []) | index("native")) != null' <<<"$DJ" >/dev/null 2>&1; then
        SAW_NATIVE_DEFAULT=1
    fi
done
# `native` is the one reviewer type whose meaning depends on a host this script cannot see.
# Host detection is "does the orchestrator have spawn_subagent" — invisible from a shell, and
# `grok` on PATH is NOT a proxy for it (a Claude Code session can have the grok CLI installed
# and answering, which is exactly the machine this fires on). So the expansion above stays
# unconditional — on Grok it is what catches a native_models slug missing from the live
# listing — and the gap is explained instead of guessed at, the same way the
# PREFLIGHT_SKIP_NETWORK note above says that those rows do not mean what they look like.
if [ "${SAW_NATIVE_DEFAULT:-0}" = 1 ] && [ "$NM_STATUS" != "OK" ]; then
    printf 'SUMMARY note: a preset names `native` but `grok models` did not answer, so no native:* entry is in SUMMARY available. On Grok Build that IS a real gap. On Claude Code it is not: there `native` collapses into `claude` and native_models is ignored, so exclude every native:* name from the defaults-vs-available membership check on that host\n'
fi
# `claude` / `claude:*` above are host reviewers on Claude Code and need no binary. On Grok
# Build the same entries mean the Claude Code CLI (`claude -p`, HOST_CLAUDE=1), and the
# claude-cli row is the only thing that says whether it can start. The script cannot see the
# host (see the native note above), so it explains the row instead of dropping the entries.
if [ "${CLAUDE_CLI_STATUS:-OK}" = MISSING ] && [ -z "$BLOCKER" ]; then
    printf 'SUMMARY note: claude-cli is MISSING. `claude` / `claude:*` in SUMMARY available are the host reviewers on Claude Code and still run there; on Grok Build they mean the Claude Code CLI and will not start until `claude` is on PATH and logged in (`claude login`).\n'
fi
# One `hint:` line, whose text was chosen with the blocker above. The literal `hint: ` prefix is
# load-bearing: the suite's closed-set gate skips this line on `$1 != "hint:"`, and $1 alone —
# the second word differs per state.
if [ -n "$BLOCKER" ]; then
    printf 'hint: %s\n' "$BLOCKER_HINT"
fi
exit 0
