#!/usr/bin/env bash
# verify-delegation.sh — did a wrapper reviewer actually DELEGATE to its external
# engine and produce a REAL review, or did it flip / stall / break?
#
# Wrapper reviewers (the codex / gemini / ext-claude / grok code-reviewers) are supposed to
# invoke their *-code-review skill, which runs the external engine and writes a run dir
# under ${DATA}/runs/<engine>/.../. Non-deterministically they sometimes "flip": skip the
# skill and self-review inline on the session's own model — a false cross-validation that
# leaves NO run dir. This script lets the /mesh-review orchestrator (Step 6.0) detect
# that mechanically instead of trusting the agent's returned text.
#
# Usage:
#   verify-delegation.sh <engine> <model|-> <since-epoch> [data-dir]
#     engine      ext-claude | codex | gemini | grok | claude
#     model       for ext-claude: "<provider>/<short>" (e.g. zai/glm); for grok: the model id
#                 (e.g. grok-4.6); "-" for codex/gemini
#     since-epoch only run dirs NAMED at/after this unix time are considered — the same
#                 window watch-runs.sh applies, and creation time rather than mtime
#                 (the orchestrator stamps this just before dispatch)
#     data-dir    optional; defaults to `config-loader.sh data-dir` (~/.local/state/mesh)
#
# ext-claude and grok runs are judged on NT = the maximum num_turns across the SUCCESSFUL
# result events of raw.jsonl (a stream can carry several: a background subagent splits it into
# a "started" segment and the resumed one that delivers the review). Errored events and
# non-integer counts never enter that maximum — see the ext-claude|grok branch for why. The two
# engines share that branch because they share the wire format: grok-exec runs the CLI with
# --output-format streaming-messages-json, which is what claude -p emits.
#
# Verdict on stdout + exit code:
#   REAL=0     finalized + agentic — ext-claude/grok: NT>1 & output.txt has non-whitespace
#              content; codex/gemini: watchdog cleanup exit 0 (when logged), non-empty output,
#              and a stream carrying a terminal event, at least one tool call, and no final
#              result with an explicit status != "success"
#   STALLED=2  died mid-flight or delivered nothing usable: no final / no result event /
#              no successful result event with an integer num_turns / final result event
#              is_error:true / engine rc!=0 / agentic but blank output — and for codex/gemini:
#              no stream file at all, no terminal event, or an error-status final result
#              (retry helps)
#   KILLED=6   a review LOST to a signal from OUTSIDE the run: the watchdog's last cleanup
#              carries 143 (SIGTERM) or 130 (SIGINT) and no watchdog.exit sits beside it, so
#              nothing inside the run decided to stop. Distinct from STALLED because retry is
#              not the remedy — whatever sent the signal sends it again. The commonest sender
#              is the harness capping a FOREGROUND Bash call at BASH_MAX_TIMEOUT_MS.
#              It answers what the signal COST, not whether one arrived: a run that had already
#              delivered a usable review scores REAL however its tail died, on every engine.
#              Every non-REAL outcome routes through `fail`, which promotes it to KILLED when
#              the run was signalled — so BROKEN also becomes KILLED for ext-claude and grok,
#              where a truncated subagent-split stream is indistinguishable from num_turns=1
#   FLIP=3     no TIMESTAMP-NAMED run dir of THIS session for this engine in the dispatch
#              window — the reviewer self-reviewed on the session model, the model argument was
#              truncated and BASE is a provider directory (its children never match the run-dir
#              shape), or every run in the window carries another session's id, which the
#              reason line names because it is the one FLIP that is not the reviewer's doing
#   BROKEN=4   finalized but non-agentic — ext-claude/grok: NT<=1; codex/gemini: terminal event
#              but zero tool calls (thinking-only / DSML grammar / answered without reading code —
#              retry futile; fix by swapping the model in config.yaml)
#   DEGRADED=5 ext-claude and grok only: everything above says REAL, but the result event's
#              `permission_denials` is non-empty — the CLI refused N of the run's tool calls,
#              so the reviewer was confined to its working directory and wrote the review
#              without the sources it tried to open. KEEP the findings (they are real, just
#              partial) and do NOT retry: the cause sits outside the run — the invocation for
#              ext-claude, the CLI's own permission config for grok. codex and gemini carry no
#              such field and cannot reach this verdict
set -u
export LC_ALL=C   # run dir names are compared with [[ < ]] and sorted; keep both byte-wise.
                  # A UTF-8 collation ignores '-' when comparing, so the name window below
                  # would disagree with watch-runs.sh on exactly the dirs it must agree on.

# 4.2, not 4.0: printf '%(fmt)T' renders --since into a run-dir name below, the same way
# watch-runs.sh does. Both scripts must resolve the same run, so both need the same builtin.
if [ "${BASH_VERSINFO[0]:-0}" -lt 4 ] ||
   { [ "${BASH_VERSINFO[0]}" -eq 4 ] && [ "${BASH_VERSINFO[1]:-0}" -lt 2 ]; }; then
    echo "verify-delegation: bash 4.2+ required (got ${BASH_VERSION:-unknown})" >&2
    exit 1
fi

# GNU find. The candidate walk below uses -printf, which BSD find does not have; without a
# probe it fails silently, no candidate survives, and EVERY reviewer is reported FLIP — a
# verdict /mesh-review acts on by re-dispatching all of them. config-loader.sh and
# watch-runs.sh carry the same probe for GNU stat, for the same reason.
find / -maxdepth 0 -printf '' >/dev/null 2>&1 || {
    echo "verify-delegation: GNU find required (BSD find has no -printf). On macOS: 'brew install findutils' and put gnubin first in PATH." >&2
    exit 1
}

resolve_plugin_data() {
    # One source of truth for where runs live: the loader's data-dir. The XDG default is the
    # fallback for a loader that cannot start, so a broken install still yields a real path.
    local d
    d="$(bash "$(cd "$(dirname "$0")" && pwd)/config-loader.sh" data-dir 2>/dev/null)" || d=""
    printf '%s\n' "${d:-${XDG_STATE_HOME:-$HOME/.local/state}/mesh}"
}

# Run identity. CLAUDE_CODE_SESSION_ID is exported into every Bash tool call and inherited
# across the agent boundary, so a run dir stamped by the *-exec skill carries the session that
# dispatched it. The body below is mirrored byte-for-byte in watch-runs.sh — the two must agree
# on which run is "the run", or the watcher reports DONE on one dir while this gate inspects
# another. FAIL-OPEN: an unstamped dir is a legacy run, a direct *-exec invocation, or a
# harness without the variable, and calling those foreign would drop a finished review.
SELF_SID="${CLAUDE_CODE_SESSION_ID:-${GROK_SESSION_ID:-}}"
# Grok wrapper children overwrite GROK_SESSION_ID with their own session id
# (measured 2026-09-01: parent 01a05eb7-…, run stamped 01a05ec0-…). Claude Code
# inherits CLAUDE_CODE_SESSION_ID across the agent boundary; Grok does not inherit
# the parent's GROK_SESSION_ID. A child-stamped run still belongs to this
# orchestrator when Grok's subagent meta names SELF_SID as parent_session_id.
# GROK_HOME overrides ~/.grok (Grok user guide). No matching meta → foreign:
# two concurrent orchestrations must not steal each other's dirs.
# Mirrored byte-for-byte in watch-runs.sh — the two must agree on which run is
# "the run", or the watcher reports DONE on one dir while this gate inspects another.
grok_child_of_self() {
    local child="$1" grok_home meta
    [ -n "$child" ] && [ -n "$SELF_SID" ] || return 1
    [[ "$child" =~ ^[A-Za-z0-9_-]+$ ]] || return 1
    [[ "$SELF_SID" =~ ^[A-Za-z0-9_-]+$ ]] || return 1
    grok_home="${GROK_HOME:-$HOME/.grok}"
    # Measured 2026-09-02 (39 files): ~/.grok/sessions/<urlencoded cwd>/<parent session
    # id>/subagents/<child id>/meta.json — the parent id is a path component under the cwd
    # dir. The flatter sessions/*/subagents/ shape is kept as a second pattern for a build
    # that drops the cwd level; before 2026-09-02 it was the ONLY pattern and matched nothing.
    for meta in "$grok_home"/sessions/*/*/subagents/"$child"/meta.json \
                "$grok_home"/sessions/*/subagents/"$child"/meta.json; do
        [ -f "$meta" ] || continue
        # Value match only — not one exact serialisation. A compacted or re-indented
        # meta.json must not turn this orchestrator's own child into a foreign run.
        grep -Eq "\"parent_session_id\"[[:space:]]*:[[:space:]]*\"$SELF_SID\"" "$meta" && return 0
    done
    return 1
}
run_is_mine() {
    [ -n "$SELF_SID" ] || return 0
    local v=""
    [ -r "$1/.session_id" ] && IFS= read -r v < "$1/.session_id"
    [ -z "$v" ] || [ "$v" = "$SELF_SID" ] || grok_child_of_self "$v"
}

ENGINE="${1:-}"
MODEL="${2:-}"
SINCE="${3:-}"
DATA_DIR="${4:-}"

[ -n "$ENGINE" ] && [ -n "$SINCE" ] || {
    echo "usage: verify-delegation.sh <engine> <model|-> <since-epoch> [data-dir]" >&2
    exit 1
}
# A non-numeric epoch used to reach `find -newermt "@$SINCE"`, which failed silently and left
# no candidate — FLIP, the verdict that says "the reviewer never delegated". Say it is a usage
# error instead: exit 1 prints no verdict, which is what the prompts read as "fix the call".
[[ "$SINCE" =~ ^[0-9]+$ ]] || {
    echo "verify-delegation: since-epoch must be a unix epoch (got '$SINCE') — did DISPATCH_EPOCH expand to nothing?" >&2
    exit 1
}
[ -n "$DATA_DIR" ] || DATA_DIR="$(resolve_plugin_data)"

case "$ENGINE" in
    ext-claude) BASE="$DATA_DIR/runs/ext-claude/$MODEL" ;;
    # A model is MANDATORY for grok, and '-' is not one: the run dirs live under
    # runs/grok/<model>/, so a missing argument would resolve to runs/grok/- and report FLIP
    # about a directory nothing ever writes. Usage error, exit 1, no verdict — the shape both
    # orchestrators read as "fix the call", not as a verdict about the reviewer.
    grok)
        case "$MODEL" in
            ''|'-') echo "verify-delegation: engine grok requires a model argument (e.g. grok-4.6), got '${MODEL:-}'" >&2; exit 1 ;;
            # Same charset as GROK_IDENT_RE in config-loader.sh, and for the same reason: this
            # value becomes a path component. A config-sourced model cannot fail it — the loader
            # already rejected anything else — but this script is also a CLI entry point and BOTH
            # orchestrators TEMPLATE the call, so the spelling that actually arrives wrong is
            # ext-claude's <provider>/<short>. That resolved runs/grok/<provider>/<short>, a path
            # nothing ever writes, and was then reported as FLIP — "this reviewer never
            # delegated" — about a reviewer that ran and delivered its review.
            *[!A-Za-z0-9._-]*|[!A-Za-z0-9]*) echo "verify-delegation: engine grok model '$MODEL' is not a catalog id (expected [A-Za-z0-9][A-Za-z0-9._-]*, e.g. grok-4.6; <provider>/<short> is ext-claude's spelling)" >&2; exit 1 ;;
        esac
        BASE="$DATA_DIR/runs/grok/$MODEL" ;;
    # Same mandatory-model / charset guards as grok: dirs live under runs/claude/<alias>/,
    # so empty/`-`/slash/leading-dot would resolve a path nothing writes and report FLIP.
    claude)
        case "$MODEL" in
            ''|'-') echo "verify-delegation: engine claude requires a model argument (e.g. opus), got '${MODEL:-}'" >&2; exit 1 ;;
            # The one documented name that is NOT a catalog alias: ext-claude-exec writes
            # runs/claude/_default/ when MODEL is omitted (the CLI-default path), and the
            # leading underscore is deliberate there — `default` would look like an alias a
            # user could put in claude.models. watch-runs.sh already admits `claude/_default`
            # (its roster class includes `_`), so without this the two consumers disagreed
            # about one literal and both orchestrators worked around it by skipping the guard
            # entirely for that reviewer — losing the dispatch-window check and the
            # permission_denials -> DEGRADED check for the fallback reviewer alone. Exact
            # literal, not a `_*` class: nothing else may start with an underscore.
            '_default') ;;
            # Same charset as GROK_IDENT_RE in config-loader.sh, and for the same reason: this
            # value becomes a path component. Unlike grok, a config-sourced model CAN fail it:
            # claude.models is validated with the wider IDENT_RE ([A-Za-z0-9._:@-]), because its
            # original role is a Task `model:` value on Claude Code, where it is never a path.
            # skills/claude-code-review/SKILL.md rejects such an alias in its own preflight,
            # before a run dir exists, so one reaching here means that gate was bypassed. Beyond
            # that, this script is also a CLI entry point and BOTH
            # orchestrators TEMPLATE the call, so the spelling that actually arrives wrong is
            # ext-claude's <provider>/<short>. That resolved runs/claude/<provider>/<short>, a path
            # nothing ever writes, and was then reported as FLIP — "this reviewer never
            # delegated" — about a reviewer that ran and delivered its review.
            *[!A-Za-z0-9._-]*|[!A-Za-z0-9]*) echo "verify-delegation: engine claude model '$MODEL' is not a catalog id (expected [A-Za-z0-9][A-Za-z0-9._-]*, e.g. opus; <provider>/<short> is ext-claude's spelling)" >&2; exit 1 ;;
        esac
        BASE="$DATA_DIR/runs/claude/$MODEL" ;;
    codex)      BASE="$DATA_DIR/runs/codex" ;;
    gemini)     BASE="$DATA_DIR/runs/gemini" ;;
    *) echo "verify-delegation: unknown engine '$ENGINE'" >&2; exit 1 ;;
esac

emit() { echo "$1"; [ -n "${2:-}" ] && echo "verify-delegation[$ENGINE${MODEL:+/$MODEL}]: $2" >&2; exit "$3"; }

# --- 1. did anything run? (run dir created in the dispatch window) ---
[ -d "$BASE" ] || emit FLIP "no run dir under ${BASE#"$DATA_DIR"/} — reviewer did not delegate (self-reviewed on the session model)" 3

# Both ELIGIBILITY and the WINNER are decided by NAME, not by mtime. Run dir names start with
# a zero-padded timestamp, so name order is creation order; mtime order is not. On bail an
# abandoned dir gains a `final` symlink, which lifts its mtime above the retry dir that
# superseded it — picking by mtime then inspects the corpse and reports STALLED while
# watch-runs.sh, which picks by name, reports DONE on the retry. mesh-design-review chains the
# two on the same run, so that disagreement discarded a finished review.
#
# Eligibility used to be `find -newermt "@$SINCE"` — MODIFICATION time — while watch-runs.sh
# compares the name against the same epoch rendered as a name. A dir created BEFORE the window
# but still being written stays mtime-eligible forever, so /mesh-review Step 6.4a, which stamps
# a FRESH epoch before re-dispatching precisely "so the guard inspects the NEW run, not the old
# failed one", still handed this script the old one: a wrapper that flipped on re-dispatch
# (no new run dir at all) was scored REAL off the previous round's corpse. Rendering --since
# into the run-dir naming and comparing names makes the two scripts' windows identical by
# construction — and drops the last -newermt, so only -printf keeps GNU find in the picture.
#
# Candidates are also SHAPE-filtered, with the same anchor as watch-runs.sh:213. In LC_ALL=C
# letters sort above digits, so any non-timestamp name — a stray `tmp/`, or the model dirs
# that become children when a truncated MODEL argument makes $BASE a provider directory —
# outranks every real run and gets inspected as if it were one, yielding a terminal STALLED.
# Filtered out, those cases fall through to FLIP, the verdict the prompts say to re-check
# against the engine/model arguments.
#
# The walk stops at the newest candidate that belongs to THIS session (run_is_mine above). A
# foreign one is skipped rather than inspected: two orchestrations of one engine/model share
# this data dir, and inspecting a stranger's run yields a terminal verdict about work nobody
# asked for. Process substitution, not a pipe — a `while` on the right of a pipe runs in a
# subshell and NEWEST would not survive it.
printf -v SINCE_STR '%(%Y-%m-%d-%H-%M-%S)T' "$SINCE"
NEWEST=""
FOREIGN=0
while IFS= read -r cand; do
    [ -n "$cand" ] || continue
    # Descending name order: the first candidate older than the window ends the walk, because
    # every one after it is older still.
    [[ "$cand" < "$SINCE_STR" ]] && break
    run_is_mine "$BASE/$cand" || { FOREIGN=$(( FOREIGN + 1 )); continue; }
    NEWEST="$BASE/$cand"; break
done < <(find "$BASE" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null |
         grep -E '^[0-9]{4}(-[0-9]{2}){5}-' | sort -r)
# "Never delegated" and "delegated, but the session id moved under us" are both FLIP, and the
# prompts act on FLIP by re-dispatching. Name the second one: it is a third cause on top of the
# two the design-review prose lists, and it is the reviewer's fault least of all.
[ -n "$NEWEST" ] || [ "$FOREIGN" = 0 ] ||
    emit FLIP "$FOREIGN run dir(s) in the dispatch window belong to another session — this session's id does not match the one that dispatched them" 3
[ -n "$NEWEST" ] || emit FLIP "no run dir newer than dispatch time — reviewer did not delegate" 3
RD="$NEWEST"

# --- 1.5. was it stopped from OUTSIDE the run? -------------------------------------------
# watchdog.sh records the two signals it can be killed by as its own exit code
# (`trap 'cleanup 143' TERM`, `trap 'cleanup 130' INT` — watchdog.sh:287-288) and writes
# `watchdog.exit` ONLY when it stops on its own judgement (retries exhausted / global timeout).
# A cleanup of 143/130 with no watchdog.exit beside it therefore says: nothing inside the run
# decided anything, the signal came from outside — and whatever sent it will send it again.
# That is the whole reason this is not STALLED, which /mesh-review Step 6.0.4 re-dispatches:
# on 2026-08-05 three such re-dispatches died exactly as the runs they replaced.
#
# The commonest sender is the harness itself. A FOREGROUND Bash call is capped at
# BASH_MAX_TIMEOUT_MS — ten minutes out of the box — and SIGTERMed at the cap, taking the whole
# process group with it; five ext-claude runs died that way at 600-605s while still writing,
# each tool result reading "Exit code 143 / Command timed out after 10m 0s", while every run
# launched with `run_in_background: true` outlived the cap (812s, 1397s, 2001s, 2028s). Every
# engine budget here sits ABOVE that cap (single_run_sec 1800, global_sec 3600), so on a
# foreground launch none of them is reachable. The launch side is fixed in the exec skills; this
# is the reading side, and it covers the two other senders seen the same day just as well — an
# orchestrator TaskStop on the wrapper, and a wrapper killing its own run.
WDOG_CLEANUP_LINE=""
WDOG_CLEANUP_RC=""
# An EXISTING but unreadable watchdog.log is not the same state as an absent one, and 2>/dev/null
# below cannot tell them apart: both leave WDOG_CLEANUP_RC empty, SIGNALLED 0, and the run falls
# through to STALLED — "retry helps" — when the evidence that would have said KILLED was simply
# not readable. Record it so `fail` can say so instead of guessing.
WDOG_UNREADABLE=0
if [ -f "$RD/watchdog.log" ] && [ ! -r "$RD/watchdog.log" ]; then
    WDOG_UNREADABLE=1
elif [ -f "$RD/watchdog.log" ]; then
    WDOG_CLEANUP_LINE="$(grep '"event":"cleanup"' "$RD/watchdog.log" 2>/dev/null | tail -1)"
    WDOG_CLEANUP_RC="$(printf '%s\n' "$WDOG_CLEANUP_LINE" |
                       grep -o '"exit_code":[[:space:]]*-\?[0-9]\+' | grep -o -- '-\?[0-9]\+$')"
fi
SIGNALLED=0
SIGNAL_NAME=""
case "$WDOG_CLEANUP_RC" in
    143) [ -f "$RD/watchdog.exit" ] || { SIGNALLED=1; SIGNAL_NAME=SIGTERM; } ;;
    130) [ -f "$RD/watchdog.exit" ] || { SIGNALLED=1; SIGNAL_NAME=SIGINT; } ;;
esac

# How long the run lived, from the log's first entry to the cleanup that ended it. Both
# orchestrators are told to report it — "terminated from outside after Ns" — and to read a cluster
# of deaths at the same round number as the foreground-cap signature, which is unreadable without
# the number. Neither can compute it: they get this reason line and nothing else. Best-effort by
# design — an unparsable stamp drops the clause rather than failing the verdict.
LIFETIME=""
if [ -n "$WDOG_CLEANUP_LINE" ]; then
    _t0="$(head -1 "$RD/watchdog.log" 2>/dev/null | grep -o '"ts":"[^"]*"' | head -1 | cut -d'"' -f4)"
    _t1="$(printf '%s\n' "$WDOG_CLEANUP_LINE" | grep -o '"ts":"[^"]*"' | head -1 | cut -d'"' -f4)"
    if [ -n "$_t0" ] && [ -n "$_t1" ]; then
        _s0="$(date -d "$_t0" +%s 2>/dev/null)" || _s0=""
        _s1="$(date -d "$_t1" +%s 2>/dev/null)" || _s1=""
        [ -n "$_s0" ] && [ -n "$_s1" ] && [ "$_s1" -ge "$_s0" ] && LIFETIME=" after $(( _s1 - _s0 ))s"
    fi
fi

# The cap raises SIGTERM and only SIGTERM, so naming it under a SIGINT states a cause that cannot
# apply — and the orchestrators relay this line verbatim. A 130 is somebody deciding: a user at
# the keyboard, or an orchestrator stopping the wrapper.
if [ "$SIGNAL_NAME" = SIGINT ]; then
    KILLED_CAUSE="SIGINT is a deliberate interrupt — a user pressing ESC, or an orchestrator stopping the wrapper that owns the run. The harness timeout is not a candidate: it raises SIGTERM"
else
    KILLED_CAUSE="A foreground Bash call is the usual sender — the harness caps one at BASH_MAX_TIMEOUT_MS (10 min by default) and SIGTERMs it there; the exec skills launch in the background for exactly this reason"
fi
KILLED_REASON="terminated from outside ($SIGNAL_NAME: watchdog cleanup exit $WDOG_CLEANUP_RC, no watchdog.exit)$LIFETIME — nothing inside the run chose to stop, so the run was healthy until the signal and simply did not get to deliver a usable review. Do NOT re-dispatch: an identical launch is killed identically. $KILLED_CAUSE"

# Every NON-REAL outcome below routes through here. KILLED answers "what did the signal COST",
# not "was there a signal": a run that had already delivered a usable review reaches `emit REAL`
# and never calls this, which is what makes the promise "a run that finalized with a real review
# before something signalled its tail still scores REAL" true on every engine rather than on
# ext-claude alone. Everything else — torn stream, blank output, no result event — is a review
# that was lost, and when the run was signalled the loss is the signal's doing, so re-dispatching
# it repeats the death rather than the review.
fail() {   # fail <verdict> <reason> <exit-code>
    [ "$SIGNALLED" = 0 ] || emit KILLED "$KILLED_REASON" 6
    [ "$WDOG_UNREADABLE" = 0 ] ||
        emit "$1" "$2 — NOTE: watchdog.log exists but is unreadable, so an outside kill could not be ruled out; KILLED is decided from that file" "$3"
    emit "$1" "$2" "$3"
}

# --- how much text counts as a review ----------------------------------------------------
# "Non-empty" was the only content test REAL ever applied, and a model that delegates the work
# and reports the delegation clears it. On 2026-08-05 deepseek/v4-pro delivered
# "Ревью запущено … Ожидаю результаты, уведомлю вас по завершении" twice, with num_turns 7 and
# 5 and 24 and 17 tool calls behind it — agentic by every signal here — and `/mesh-review`
# counted both as cross-validating reviewers. A stub that passes is worse than a run that fails:
# it inflates "N models agreed" with a model that said nothing.
#
# The floor is a length, because nothing more specific survives contact with the archive: the
# stubs use no distinguishing tool, no distinguishing turn count (a genuine 460-byte review ran
# 15 turns, a stub ran 7), and keying on their wording is the mistake the permission_denials
# check below already documents. Measured over every archived run with a non-empty output — 336
# ext-claude, 78 codex — everything under 400 non-space bytes was a stub, a torn fragment,
# leaked tool grammar or an "approve this command" note, while the shortest genuine review
# measured 460 (ext-claude) and 1746 (codex). BYTES, not characters: LC_ALL=C is set above for
# reasons of its own, so `wc -c` is what there is — which makes the floor stricter for Cyrillic
# (~2 bytes per character) than for ASCII, and Cyrillic reviews are what calibrated it.
#
# STALLED rather than BROKEN, and so through `fail`: a stub is not proof the engine cannot
# review — the run that delivered the 11428-byte review the same day was the same kind of model
# on a later attempt — so one re-dispatch is a fair use of the budget, and a signalled run stays
# KILLED.
MIN_REVIEW_BYTES=400
# "Read×2, Bash×1" — which tools were refused says whether the reviewer lost source files,
# searches, or both, and a bare count does not. One function because both the BROKEN promotion
# and the DEGRADED emit print it, from the same $DENIED_TOOLS.
denial_breakdown() {
    printf '%s\n' "$DENIED_TOOLS" | grep '[^[:space:]]' | sort | uniq -c |
        sort -rn | awk '{printf "%s%s×%s", (n++ ? ", " : ""), $2, $1}'
}

out_bytes() { tr -d '[:space:]' < "$1" 2>/dev/null | wc -c | tr -d ' '; }

# --- 2. did it finalize? (died mid-flight = no final symlink AND no root output.txt) ---
if [ ! -e "$RD/final" ] && [ ! -f "$RD/output.txt" ]; then
    fail STALLED "run dir present but not finalized (killed mid-flight)" 2
fi

# -s, not -f, on the root file: gemini-exec pre-creates a zero-byte output.txt at launch and
# the supervised copy-up can land one, and an EXISTING-but-empty root would then win over a
# final/output.txt that holds the actual review. watch-runs.sh:279 picks the same file with -s
# and reports DONE; with -f here the gate answered STALLED on the run the watcher had just
# called finished, and design review's failure path drops it for good.
OUT="$RD/output.txt"; [ -s "$OUT" ] || OUT="$RD/final/output.txt"

# --- 3. is the content a REAL review? ---
case "$ENGINE" in
    codex|gemini)
        # These CLIs carry no type:result/num_turns, so this branch used to check only
        # `.watchdog_rc` — which nothing under skills/ writes, only test fixtures — and then a
        # non-empty output.txt. That made it a no-op: it asked exactly what the caller already
        # knew, and a narration-only file passed as REAL. Use the signals that are on disk.
        RCF="$RD/.watchdog_rc"
        if [ -f "$RCF" ]; then
            RCV=""; IFS= read -r RCV < "$RCF" 2>/dev/null || true
            # Through `fail`, not `emit`: this check runs before the signal is weighed, and a 143
            # in this file used to be reported as "engine exit code != 0" — masking KILLED behind
            # a verdict that re-dispatches. Nothing under skills/ writes the file today (see
            # above), but the test fixtures do, and a future writer would inherit the mask.
            [ "$RCV" = "0" ] || fail STALLED "engine exit code != 0 ($RCV)" 2
        fi
        # The watchdog records its own exit in watchdog.log; that file really is written. Read it
        # from the value step 1.5 already parsed, so both readings of the same field can never
        # disagree. A SIGNALLED run deliberately falls THROUGH to the content checks instead of
        # emitting here: this branch sees runs that DID finalize, so a codex run signalled after
        # writing a complete review reaches `emit REAL` below and keeps its findings. Everything
        # further down routes through `fail`, so if the review is not usable the verdict is still
        # KILLED — just decided by what was lost rather than by the exit code alone.
        if [ -n "$WDOG_CLEANUP_RC" ] && [ "$WDOG_CLEANUP_RC" != 0 ] && [ "$SIGNALLED" = 0 ]; then
            emit STALLED "watchdog cleanup exit code $WDOG_CLEANUP_RC" 2
        fi
        [ -s "$OUT" ] || fail STALLED "output.txt empty — no usable review produced" 2
        # Content, when a stream is present. codex emits turn.completed / command_execution;
        # gemini emits result / tool_use. No terminal event means the CLI was killed mid-flight
        # and output.txt is salvage. A terminal event with no tool call at all is the codex and
        # gemini analogue of ext-claude's num_turns<=1: it finished, and it did nothing —
        # exactly the 47429-byte narration draft this gate exists to stop.
        STREAM="$RD/raw.jsonl"
        [ -s "$STREAM" ] || STREAM="$RD/final/raw.jsonl"
        [ -s "$STREAM" ] || STREAM="$RD/log.jsonl"
        if [ -s "$STREAM" ]; then
            grep -q '"type":"turn\.completed"\|"type":"result"' "$STREAM" 2>/dev/null ||
                fail STALLED "stream has no terminal event — killed mid-flight" 2
            # gemini can exit 0 while reporting an API failure as a result event with
            # status!="success" — gemini-exec's own extraction then writes "API Error: …" into
            # output.txt (SKILL.md:350-357), so every other signal here looks healthy. Reject an
            # explicit non-success status on the LAST result event; a result carrying no status
            # field stays accepted — the documented success shape does not promise one, and a
            # false STALLED discards a finished review. codex streams have no "type":"result"
            # lines at all (turn.completed is their terminal), so this never fires for codex.
            LAST_RES="$(grep '"type":"result"' "$STREAM" 2>/dev/null | tail -1)"
            if printf '%s\n' "$LAST_RES" | grep -q '"status"' &&
               ! printf '%s\n' "$LAST_RES" | grep -q '"status":[[:space:]]*"success"'; then
                fail STALLED "final result event carries status != \"success\" — the engine reported an error, not a review" 2
            fi
            # `emit`, not `fail`: a terminal turn event with zero tool calls says the CLI finished
            # its turn and did nothing, which no signal can explain away — and unlike ext-claude
            # there is no subagent-split shape here for a kill to truncate into this one. Reporting
            # such a run as KILLED would blame the launch for a model that narrated.
            grep -q '"type":"command_execution"\|"type":"tool_use"' "$STREAM" 2>/dev/null ||
                emit BROKEN "terminal event but no tool call — narration, not a review" 4
        else
            # Every layout the exec skills produce carries a stream: supervised runs get root
            # raw.jsonl copied back, default-mode runs write log.jsonl (0 of 75 archived runs
            # lack both). No stream means the layout is not one our tooling wrote — nothing can
            # prove the run was agentic, so fail closed instead of silently skipping the gate.
            fail STALLED "no stream file (raw.jsonl / log.jsonl) — cannot verify the run did anything" 2
        fi
        # The review floor comes AFTER the tool-call check, not before it: "finished a turn and
        # ran nothing" is a broken engine whatever length its narration reached, and BROKEN says
        # so precisely. A run that DID work and then delivered two sentences is the other case.
        OUT_BYTES="$(out_bytes "$OUT")"
        [ "$OUT_BYTES" -ge "$MIN_REVIEW_BYTES" ] ||
            fail STALLED "the run used tools but output.txt holds only $OUT_BYTES non-space bytes — a notice or a fragment, not a review (the shortest genuine codex review in the archive is 1746)" 2
        emit REAL "delegated, non-empty review" 0
        ;;
    ext-claude|grok|claude)
        # grok joins this branch rather than getting one of its own because it shares the
        # STREAM FORMAT, not merely the spirit: grok-exec runs the CLI with
        # --output-format streaming-messages-json, which is the Claude Code wire format byte
        # for byte, so is_error, num_turns and permission_denials are all on disk here too.
        # Only two sentences below are engine-specific, and both are lifted into a
        # `case "$ENGINE"` of their own; everything else states a fact about the stream, which
        # is the same fact for both engines.
        #
        # num_turns is the authoritative signal that the model did agentic work (read code /
        # ran tools). Classify on it directly — it is robust to HOW a non-review surfaces
        # (empty output, thinking-only, or DSML tool-grammar leaked as literal text), so it
        # depends on neither sniffing output.txt for marker strings nor the thinking-fallback
        # that used to populate output.txt.
        #
        # Take the MAXIMUM over all SUCCESSFUL result events, not the last one: a run that
        # dispatches a background subagent answers "started", then resumes and delivers the real
        # review, and progress-monitor.sh appends both segments to the same raw.jsonl. The
        # closing segment's num_turns counts only itself (1), so `tail -1` would call a genuine
        # review BROKEN — the one verdict mesh-review never retries. max and not sum: summing
        # two non-agentic segments (1+1) would fake a REAL.
        #
        # Only successful events, and only integer counts, may enter that maximum:
        #   - is_error:true carries a turn count that measured a FAILURE. Real streams do this —
        #     five historical run dirs hold {"subtype":"success","is_error":true,"num_turns":95,
        #     "result":"Prompt is too long"} (note subtype lies; is_error is the signal), and both
        #     `tail -1` and a naive max elect 95, admitting that 18-character string as a REAL
        #     cross-validation.
        #   - a non-integer would reach `[ "$NT" -le 1 ]`, where `[` errors, the error is
        #     swallowed by 2>/dev/null, the `if` reads false and the run falls through to REAL.
        # Reading each line as a raw string (`jq -R`) is what keeps a truncated final line — the
        # shape a killed, live-appended stream leaves — from aborting the scan.
        RAW="$RD/raw.jsonl"; [ -f "$RAW" ] || RAW="$RD/final/raw.jsonl"

        # progress-monitor.sh:171-175 REWRITES output.txt from every result event, so the text
        # actually delivered is the LAST segment's. If that segment failed, the run delivered no
        # review however agentic the earlier ones were — and the lone "\n" it leaves behind would
        # sail through a bare `[ -s ]`. Retry can help, so STALLED rather than BROKEN.
        LAST_ERR="$(grep -h '"type":"result"' "$RAW" 2>/dev/null \
            | jq -Rr 'fromjson? | objects | select(.type == "result") | .is_error' 2>/dev/null | tail -1)"
        if [ "$LAST_ERR" = "true" ]; then
            # A failed run that took ZERO turns did not die mid-flight — it never started, and
            # STALLED's "retry helps" is the wrong instruction for it. The shape is a CLI that
            # refused its own arguments: measured 2026-08-30, `grok -m grok-4.6 --effort max`
            # exits 1 in 4.7s BEFORE any API call with a single
            # {"type":"result","is_error":true,"num_turns":0,"errors":[…]} event, which
            # watchdog.sh:260 counts as attempt success and extract-result.py's F4 arm turns into
            # a non-empty output.txt. Every retry dies identically, so a STALLED here spends the
            # whole max_redispatch budget on an error no retry can fix.
            #
            # The discriminator is num_turns == 0 and NOTHING ELSE — specifically NOT "errors[]
            # is non-empty", which was the first proposal. Measured across 1067 archived
            # ext-claude run files: is_error:true with a non-empty errors[] is ORDINARY there
            # (num_turns 2 through 62, dozens of runs, several of which a retry did fix), while
            # num_turns == 0 appears in NONE of them — the archive's minimum is 1. So the errors[]
            # form would have made retryable ext-claude failures terminal.
            #
            # This is the SAME judgement the `NT <= 1` arm below already makes for both engines,
            # reaching runs that cannot get there because this check fires first. Read from the
            # last result event whatever its is_error, since the NT scan below deliberately
            # counts only successful events.
            # `tail -1` FIRST, on the LINE, then read that one event. With the order reversed
            # `numbers` dropped null and absent counts BEFORE tail saw them, so LAST_NT could
            # come from an EARLIER event than the one being judged — the name and the sentence
            # above it both promise the last. Two shapes it got wrong: a final event with no
            # num_turns and an earlier success at 0 elected that 0 and fired BROKEN with "failed
            # before taking a single turn" about a run that took several; a final null with an
            # earlier 5 judged the failure by the healthy segment's count. Neither is reachable
            # in 904 archived streams — the two readings disagree on exactly one, a file whose
            # last line is truncated, and there neither value is 0 — so this corrects the read
            # without moving any verdict that has ever been issued. Unparseable or absent now
            # yields the empty string, which is not "0", so the terminal verdict does not fire.
            LAST_NT="$(grep -h '"type":"result"' "$RAW" 2>/dev/null | tail -1 \
                | jq -Rr 'fromjson? | objects | select(.type == "result")
                          | .num_turns | numbers | select(. == floor and . >= 0)' 2>/dev/null)"
            if [ "$LAST_NT" = "0" ]; then
                ZERO_WHY="the engine failed before taking a single turn (num_turns=0) — an argument or start-up refusal, not a review that died mid-flight. Retry is futile: the same invocation is refused identically"
                if [ "$ENGINE" = "grok" ]; then
                    ZERO_WHY="$ZERO_WHY. The usual cause is a --effort the model does not accept: the CLI validates it PER MODEL at argument parsing, and the accepted sets differ (grok-4.6 takes xhigh|high|medium|low, not max). output.txt carries the CLI's own message; fix grok.reasoning_effort / grok.model_efforts in config.yaml, which is user-owned"
                fi
                fail BROKEN "$ZERO_WHY" 4
            fi
            fail STALLED "final result event is_error:true — the delivered output is the failed segment, not a review" 2
        fi

        NT="$(grep -h '"type":"result"' "$RAW" 2>/dev/null \
            | jq -Rr 'fromjson? | objects | select(.type == "result" and .is_error == false)
                      | .num_turns | numbers | select(. == floor and . >= 0)' 2>/dev/null \
            | sort -n | tail -1)"
        if [ -z "$NT" ]; then
            # finalized dir but no successful result event carried an integer num_turns
            fail STALLED "no usable result event in raw.jsonl — killed mid-flight" 2
        fi
        # Read the denials HERE, above the BROKEN promotion, because BOTH verdicts consume them.
        # A run can be refused its very first tool call and stop after one turn: the promotion
        # below then calls it BROKEN — rightly, a single turn is not a review whatever caused it
        # — but its own text says "retry futile", i.e. swap the model, about a model that did
        # nothing wrong, while the branch that knows better sits past the floor checks and is
        # never reached. Reading the field once, before both, is what lets the BROKEN reason name
        # the refusal while the DEGRADED reason below keeps its own wording. The EMIT stays down
        # there: a denied run that did review must still pass the floor checks first.
        # Every check above can pass on a run that never got outside its own cwd. Under `-p`
        # a permission prompt has nobody to answer it, so the CLI auto-denies: the reviewer
        # loses the sibling repositories it needs to check an API signature against real
        # source, falls back to guessing, and still finalizes with is_error:false and a
        # healthy num_turns. Nothing above can see that — on 2026-08-04 five reviewers came
        # back this way and this gate called every one of them REAL.
        #
        # The signal is `permission_denials` on the result event: one entry per refusal,
        # carrying the tool name and the exact input that was refused (verified on CC 2.1.221,
        # 2026-08-04 — a refused Read yields tool_name "Read", a refused Bash "Bash", and a run
        # under --permission-mode bypassPermissions yields []). Read it rather than grepping
        # the refusal text out of tool_result bodies, which is what the first version of this
        # check did and which fails in BOTH directions: it misses every wording that was not
        # sampled (the CLI has several, and the Bash one contains no "permission" at all), and
        # it fires on any FAILED tool call whose OUTPUT happens to quote one — grepping this
        # repository does exactly that, since the wordings are written down in it.
        #
        # Successful segments only, matching NT above: a stream split by a background subagent
        # carries several result events, and refusals belonging to an abandoned segment did not
        # constrain the review that was actually delivered. Summed and not maxed — each entry is
        # one refusal, not a running total.
        #
        # This cannot fail open. NT above is pulled from the same field of the same events of
        # the same file by the same jq; a broken jq, an unreadable $RAW or a stream with no
        # parsable result event leaves NT empty and exits STALLED before reaching this line. A
        # result event that simply omits the field (an older build) yields no entries and stays
        # REAL — absent is not denied. Note what that costs in the other direction: DENIED=0 is
        # "no denials" and "no such field" at once, and nothing here can tell them apart. On
        # grok every measured run has been the second case — the field was absent from every
        # result event observed while this branch was written — so a grok run scoring REAL is
        # not evidence that its CLI refused nothing, and DEGRADED stays a verdict grok is
        # eligible for rather than one it has been seen to reach. Read raw.jsonl to settle it.
        DENIED_TOOLS="$(grep -h '"type":"result"' "$RAW" 2>/dev/null \
            | jq -Rr 'fromjson? | objects | select(.type == "result" and .is_error == false)
                      | .permission_denials | arrays | .[] | .tool_name // "unknown"' 2>/dev/null)"
        DENIED="$(printf '%s\n' "$DENIED_TOOLS" | grep -c '[^[:space:]]')"

        # `fail`, not `emit`, and this is the one BROKEN that a signal DOES move. A run that
        # dispatches a background subagent answers "started" with num_turns 1 and delivers the
        # review in a later segment of the same stream; a kill landing between the two leaves
        # exactly this shape. BROKEN is terminal — mesh-review never retries it — and its reason
        # tells the user to swap a model that did nothing wrong, so on a signalled run the honest
        # verdict is KILLED. Unsignalled, it stays BROKEN.
        if [ "$NT" -le 1 ]; then
            BROKEN_WHY="model produced no agentic review (thinking-only / DSML / answered without reading code — retry futile)"
            if [ "$DENIED" -gt 0 ]; then
                BROKEN_WHY="the CLI refused $DENIED tool call(s) ($(denial_breakdown)) and the model stopped after one turn — a permission problem, not an unsuitable model. Check the CLI's own permission configuration before swapping the model; the verdict stays terminal because one turn is not a review"
            fi
            fail BROKEN "num_turns=$NT: $BROKEN_WHY" 4
        fi
        # The floor is one number for both engines; the sentence that explains it is not.
        # The archive citation (336 runs) is a fact about ext-claude, so ext-claude is what
        # names it — not `*)`. grok has no archive yet and quoting one would be a measurement
        # nobody made, and the same is true of any engine appended to this branch later: the
        # default arm states the floor itself, which is true of every engine judged by it.
        case "$ENGINE" in
            ext-claude) FLOOR_NOTE="the shortest genuine review in the archive is 460" ;;
            *)          FLOOR_NOTE="the floor is $MIN_REVIEW_BYTES non-space bytes" ;;
        esac
        # num_turns > 1: genuinely agentic — require output with actual content to call it REAL.
        OUT_BYTES="$(out_bytes "$OUT")"
        if [ "$OUT_BYTES" = 0 ]; then
            fail STALLED "num_turns=$NT but output.txt has no content — retry" 2
        elif [ "$OUT_BYTES" -lt "$MIN_REVIEW_BYTES" ]; then
            fail STALLED "num_turns=$NT but output.txt holds only $OUT_BYTES non-space bytes — the run worked and then delivered a notice, not a review ($FLOOR_NOTE)" 2
        fi

        # --- was it allowed to READ what it reviewed? ---
        # DENIED and DENIED_TOOLS are computed above, before the BROKEN promotion, because that
        # promotion consumes them too — see the comment there. This branch owns only what to DO
        # about a refusal on a run that WAS agentic.
        if [ "$DENIED" -gt 0 ]; then
            BREAKDOWN="$(denial_breakdown)"
            # The refusal is the same event on both engines; what to DO about it is not.
            # ext-claude's remedy is the missing flag — grok-exec already passes it, so naming
            # it here would send the reader after a setting that cannot be the cause.
            # Each arm is named, and the default one names no engine: an engine appended to
            # this branch's `ext-claude|grok)` head would otherwise be handed ext-claude's
            # remedy — a flag its own exec skill may already pass, or may not accept at all.
            case "$ENGINE" in
                grok)       DENIAL_REMEDY="grok-exec already passes --permission-mode bypassPermissions, so this is not the missing-flag case: the CLI refused for a reason of its own (a sandbox profile, or a deny rule in ~/.grok). Keep the findings; do NOT re-dispatch, and check the CLI's own permission configuration" ;;
                claude)     DENIAL_REMEDY="HOST_CLAUDE already passes --permission-mode bypassPermissions, so this is not the missing-flag case: the CLI refused for a reason of its own (a sandbox profile, or a deny rule in the claude CLI config). Keep the findings; do NOT re-dispatch" ;;
                ext-claude) DENIAL_REMEDY="Keep the findings; do NOT re-dispatch, an identical invocation is refused identically. The remedy is the user's, not an agent's: the ext-claude run needs --permission-mode bypassPermissions, and an installed plugin only picks that up through a release" ;;
                *)          DENIAL_REMEDY="Keep the findings; do NOT re-dispatch, an identical invocation is refused identically. The cause sits outside the run: read how this engine's exec skill invokes the CLI, and the CLI's own permission configuration" ;;
            esac
            emit DEGRADED "num_turns=$NT but the CLI refused $DENIED tool call(s) ($BREAKDOWN) — the reviewer was confined to its working directory and reviewed on incomplete context. $DENIAL_REMEDY" 5
        fi
        emit REAL "delegated, agentic review (num_turns=$NT)" 0
        ;;
esac
