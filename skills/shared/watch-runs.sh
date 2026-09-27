#!/usr/bin/env bash
# watch-runs.sh — is each dispatched executor finished, still working, or dead?
#
# The /mesh-review (Step 5a) and /mesh-design-review (Step 6) orchestrators disk-watch their
# executors. Finalization is easy to see; DEATH is not — a dead executor and a slow one leave
# exactly the same disk: nothing changes. Both orchestrators used to hand-roll the poll loop
# from prose, and both arrived at "exit when the finished count grows", which death never does.
# On 2026-07-26 four executors died mid-stream and the orchestrator stayed silent for 38
# minutes. This script is that loop, written once.
#
# Usage:
#   watch-runs.sh --since EPOCH [--stall-sec N] [--poll-sec N] [--once] [--data-dir DIR]
#                 <engine[/provider/model]>...
#
# The positional arguments are a ROSTER — the subpath under <data-dir>/runs/, e.g. `codex` or
# `ext-claude/zai/glm` — and NOT run directories. An executor that dies and self-retries creates
# a NEW run dir; a fixed list would keep watching the abandoned one, see it go quiet, and report
# a LIVE executor dead. The newest dir at/after --since is re-resolved on every evaluation.
#
# Pass ONLY the executors still being waited for. The baseline is virtual — every entry is
# assumed RUN — so anything else is news and exits immediately. An entry already handled comes
# straight back as news; that is the signal that the roster was not narrowed.
#
# Status per roster entry:
#   DONE     terminal, watchdog exit code 0 (or no watchdog at all), and output.txt non-empty
#   FAILED   terminal, anything else — including a bail, an external kill, and rc=0 with no output
#   SILENT   not terminal, nothing written for longer than the stall threshold
#   RUN      not terminal and writing recently, or no dir yet inside the startup grace
#   MISSING  no run dir at/after --since once the grace has elapsed
#
# EVERY verdict exits 0. The harness surfaces a non-zero background exit as "failed with exit
# code N", and an LLM orchestrator reads that as an error. A non-zero exit (64) means THIS
# SCRIPT is broken — bad arguments, missing dependency — never that an executor died.
set -u
export LC_ALL=C   # run dir names are compared with [[ < ]]; keep collation byte-wise

if [ "${BASH_VERSINFO[0]:-0}" -lt 4 ] ||
   { [ "${BASH_VERSINFO[0]}" -eq 4 ] && [ "${BASH_VERSINFO[1]:-0}" -lt 2 ]; }; then
    echo "watch-runs: bash 4.2+ required (got ${BASH_VERSION:-unknown}) — printf '%(fmt)T' formats every timestamp here, so no date(1) is needed" >&2
    exit 64
fi

# The only non-builtin dependency. BSD stat spells this `-f %m`; config-loader.sh carries the
# same probe for the same reason.
stat -c %Y "$0" >/dev/null 2>&1 || {
    echo "watch-runs: GNU stat required (BSD stat uses -f). On macOS: 'brew install coreutils' and put gnubin first in PATH." >&2
    exit 64
}

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
LOADER="$SELF_DIR/config-loader.sh"

STALL_FLOOR=600
DEADLINE_MARGIN=300
# How long after a supervised run stops writing we still expect its output.txt to appear.
# watchdog.sh never writes that file — the *-exec skill extracts it from raw.jsonl after the
# watchdog returns. Measured across 249 archived successful runs the gap is 0-33s, so 60
# clears the worst observed case with margin while staying far under the stall threshold.
SETTLE_SEC=60

SINCE=""
STALL_SEC=""
POLL_SEC=30
ONCE=0
DATA_DIR=""
ROSTER=()

# Run identity. CLAUDE_CODE_SESSION_ID is exported into every Bash tool call and inherited
# across the agent boundary (verified 2026-07-28: a subagent's Bash call sees the
# orchestrator's value), so a run dir stamped by the *-exec skill at creation carries the
# session that dispatched it. Two orchestrations of one engine/model share the global data
# dir, and without this the newest dir wins even when it belongs to someone else's dispatch.
SELF_SID="${CLAUDE_CODE_SESSION_ID:-${GROK_SESSION_ID:-}}"

is_pos_int() { [[ "${1:-}" =~ ^[1-9][0-9]*$ ]]; }
die() { echo "watch-runs: $1" >&2; exit 64; }
usage() {
    echo "usage: watch-runs.sh --since EPOCH [--stall-sec N] [--poll-sec N] [--once] [--data-dir DIR] <engine[/provider/model]>..." >&2
    exit 64
}

while [ $# -gt 0 ]; do
    case "$1" in
        --since)     SINCE="${2:-}";     shift 2 || usage ;;
        --stall-sec) STALL_SEC="${2:-}"; shift 2 || usage ;;
        --poll-sec)  POLL_SEC="${2:-}";  shift 2 || usage ;;
        --data-dir)  DATA_DIR="${2:-}";  shift 2 || usage ;;
        --once)      ONCE=1; shift ;;
        --)          shift; while [ $# -gt 0 ]; do ROSTER+=("$1"); shift; done ;;
        -*)          die "unknown option '$1'" ;;
        *)           ROSTER+=("$1"); shift ;;
    esac
done

# A caller with nothing left to watch should not invoke the watcher at all.
[ "${#ROSTER[@]}" -gt 0 ] || usage

# A roster entry is a subpath under runs/ and nothing else. Unvalidated, an empty entry — one
# stray space in a substituted roster — resolves to runs/ itself, and `ext-claude/zai/..`
# resolves to a provider directory; both then report a plausible RUN forever instead of the
# "check the roster entry" warning below. Silent blindness is the failure this script exists
# to remove, so a malformed entry is a usage error, not something to watch.
for _entry in "${ROSTER[@]}"; do
    [[ "$_entry" =~ ^[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)*$ ]] ||
        die "invalid roster entry '$_entry' — expected engine[/provider/model]"
    case "/$_entry/" in
        */./*|*/../*) die "invalid roster entry '$_entry' — '.' and '..' are not path components" ;;
    esac
done

# Every option validates the same way. A silent fallback on one of them is how
# `--stall-sec --once <entry>` used to swallow the flag and then block forever.
is_pos_int "$POLL_SEC" || die "--poll-sec must be a positive integer (got '$POLL_SEC')"
[ -z "$STALL_SEC" ] || is_pos_int "$STALL_SEC" || die "--stall-sec must be a positive integer (got '$STALL_SEC')"
is_pos_int "$SINCE" || die "--since is required and must be a unix epoch (got '$SINCE') — did DISPATCH_EPOCH expand to nothing?"

printf -v NOW '%(%s)T' -1
[ "$SINCE" -le $(( NOW + 60 )) ] || die "--since is in the future ($SINCE)"
[ "$SINCE" -ge $(( NOW - 86400 )) ] || die "--since is more than a day old ($SINCE) — did DISPATCH_EPOCH expand to nothing?"

if [ -z "$DATA_DIR" ]; then
    [ -x "$LOADER" ] || die "config-loader.sh not found beside watch-runs.sh — pass --data-dir"
    DATA_DIR="$("$LOADER" data-dir 2>/dev/null)"
fi
[ -n "$DATA_DIR" ] || die "data dir not resolved"
# The XDG state dir appears with the first exec run. A watcher launched right after dispatch on a
# machine that never ran one must watch an empty tree (rows RUN, then MISSING), not die.
mkdir -p "$DATA_DIR" 2>/dev/null; [ -d "$DATA_DIR" ] || die "data dir missing and cannot be created: '$DATA_DIR'"

# One loader call serves both timeouts below — the two keys live in the same JSON document, and
# get-runtime re-reads and re-validates config.yaml on every invocation.
RUNTIME_JSON=""
[ -x "$LOADER" ] && RUNTIME_JSON="$("$LOADER" get-runtime 2>/dev/null)"
runtime_timeout() { printf '%s' "$RUNTIME_JSON" | jq -r ".timeouts.$1 // empty" 2>/dev/null; }

# Threshold: the caller's flag, else runtime.timeouts.stall_sec, else the floor. jq is optional —
# without it the substitution yields nothing and the fallback takes over, loudly.
if [ -z "$STALL_SEC" ]; then
    STALL_SEC="$(runtime_timeout stall_sec)"
    is_pos_int "$STALL_SEC" || {
        echo "watch-runs: runtime.timeouts.stall_sec not resolved — using $STALL_FLOOR" >&2
        STALL_SEC="$STALL_FLOOR"
    }
fi
if [ "$STALL_SEC" -lt "$STALL_FLOOR" ]; then
    echo "watch-runs: stall threshold $STALL_SEC raised to $STALL_FLOOR — every exec skill that pins its own stall budget hardcodes HARD_ZERO_TIMEOUT=600 (codex, gemini and grok today; ext-claude reads the configured threshold instead), so a lower threshold would call a live run silent before its own watchdog acts" >&2
    STALL_SEC="$STALL_FLOOR"
fi

# The deadline lives HERE, not in the prompt. The watcher restarts after every event, so a
# relative budget would reset each time and never expire; and arithmetic over a shell variable
# in a prompt silently collapses to nonsense, because shell state does not survive between
# Bash-tool calls. Deriving it from --since makes that whole class of failure impossible.
GLOBAL_SEC="$(runtime_timeout global_sec)"
is_pos_int "$GLOBAL_SEC" || {
    # Say so. The neighbouring stall_sec fallback warns, and a deadline silently reset to the
    # default is the one substitution in this script that nobody could otherwise notice.
    echo "watch-runs: runtime.timeouts.global_sec not resolved — using 3600" >&2
    GLOBAL_SEC=3600
}
DEADLINE=$(( SINCE + GLOBAL_SEC + DEADLINE_MARGIN ))

# Run dir names begin YYYY-MM-DD-HH-MM-SS-<pid>. The TIMESTAMP prefix is fixed width and zero
# padded, so a lexicographic comparison against the same rendering of --since is an exact
# creation-time window. The pid suffix is NOT fixed width — "-999999" sorts above "-1000000" —
# so ordering within a single second is arbitrary. The window only needs second resolution.
printf -v SINCE_STR '%(%Y-%m-%d-%H-%M-%S)T' "$SINCE"

declare -A WARNED_BASE=()
RUNDIR_PATH=""
FOREIGN=0
NEWEST=0
STATUS=""
QUIET=""
LAST=""
DETAIL=""
RUNDIR=""
STATUSES=()
ROWS=""

# A candidate belongs to this dispatch. The body is mirrored byte-for-byte in
# verify-delegation.sh — the two must agree on which run is "the run", or the watcher reports
# DONE on one directory while the gate inspects another. FAIL-OPEN by design: an unstamped dir
# is a run from a plugin version older than this stamp, a direct *-exec invocation, or a
# harness that does not export the variable. Calling those foreign would resolve nothing and
# report MISSING for a live run — the one thing this whole feature exists not to do.
# Grok wrapper children overwrite GROK_SESSION_ID with their own session id
# (measured 2026-09-01: parent 01a05eb7-…, run stamped 01a05ec0-…). Claude Code
# inherits CLAUDE_CODE_SESSION_ID across the agent boundary; Grok does not inherit
# the parent's GROK_SESSION_ID. A child-stamped run still belongs to this
# orchestrator when Grok's subagent meta names SELF_SID as parent_session_id.
# GROK_HOME overrides ~/.grok (Grok user guide). No matching meta → foreign.
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

# The newest run dir for a roster entry, at/after --since. Selection is by NAME, not mtime: on
# bail the abandoned dir gains a `final` symlink, which bumps its mtime above the retry dir's,
# and selecting by mtime would follow the corpse.
resolve_run_dir() {
    local entry="$1" base="$DATA_DIR/runs/$1" name d i
    local -a cands=()
    RUNDIR_PATH=""
    FOREIGN=0
    if [ ! -d "$base" ]; then
        [ -n "${WARNED_BASE[$entry]:-}" ] || {
            echo "watch-runs: no runs directory for '$entry' ($base) — check the roster entry" >&2
            WARNED_BASE[$entry]=1
        }
        return 1
    fi
    for d in "$base"/*/; do
        [ -d "$d" ] || continue
        name="${d%/}"; name="${name##*/}"
        # Only timestamped run dirs are candidates. Anything else — a stray `tmp/`, or a
        # provider directory reached through a malformed entry — sorts ABOVE every timestamp
        # (letters outrank digits) and would shadow the entry not just now but for every
        # future run under it, reporting a finished review as SILENT forever.
        [[ "$name" =~ ^[0-9]{4}(-[0-9]{2}){5}- ]] || continue
        [[ "$name" < "$SINCE_STR" ]] && continue
        cands+=("$name")
    done
    # Bash expands a glob in ascending byte order (LC_ALL=C, :35), so walking the array
    # backwards is newest-first. Take the newest that is ours; reading the stamp only as far
    # as the walk goes keeps the common case at a single file read.
    for (( i=${#cands[@]}-1; i>=0; i-- )); do
        run_is_mine "$base/${cands[i]}" || { FOREIGN=$(( FOREIGN + 1 )); continue; }
        RUNDIR_PATH="$base/${cands[i]}"
        return 0
    done
    return 1
}

# Freshness is the newest mtime across every stream a run can be writing.
#  - supervised: the CLI writes attempt-N/raw.jsonl and root raw.jsonl appears only at the end,
#    but watchdog.log gets an `alive` heartbeat every 60s, so the gap between retries is covered;
#  - unsupervised codex: log.jsonl only, no raw.jsonl at all;
#  - watchdog dead but CLI alive: attempt-*/raw.jsonl still moves.
# Erring toward "do not declare a live run dead" is deliberate; the deadline is the backstop.
newest_mtime() {
    local d="$1" m f
    NEWEST=0
    for f in "$d/raw.jsonl" "$d/log.jsonl" "$d/watchdog.log" "$d"/attempt-*/raw.jsonl; do
        [ -f "$f" ] || continue
        m="$(stat -c %Y "$f" 2>/dev/null)" || continue
        [ -n "$m" ] || continue
        [ "$m" -gt "$NEWEST" ] && NEWEST="$m"
    done
    # No stream file yet — fall back to the run dir's own mtime, which is the launch time. That
    # keeps a just-created run out of SILENT, but it also means freshness says nothing about the
    # CLI during this window: a watchdog that died before writing its first line looks exactly
    # like a CLI that has not answered yet. NEWEST_FROM_DIR carries that to the row, so a SILENT
    # verdict in this state reads as "nothing was ever written" rather than "it went quiet".
    NEWEST_FROM_DIR=0
    [ "$NEWEST" != 0 ] || { NEWEST="$(stat -c %Y "$d" 2>/dev/null || printf '0')"; NEWEST_FROM_DIR=1; }
}

classify() {
    local entry="$1" d wl line rc out has_out
    STATUS=""; QUIET=""; LAST=""; DETAIL=""; RUNDIR=""; NEWEST_FROM_DIR=0

    if ! resolve_run_dir "$entry"; then
        # No dir yet is normal right after dispatch: an executor still booting must not be
        # declared dead in milliseconds. Grace runs from --since, so no extra option is needed.
        if [ $(( NOW - SINCE )) -gt "$STALL_SEC" ]; then STATUS=MISSING; else STATUS=RUN; fi
        # "Nobody dispatched anything" and "the run in this window belongs to another session"
        # are the same MISSING row, and the prompts route MISSING to "the executor is dead".
        # Say which one it is: a session id that changed mid-orchestration (a resumed or forked
        # session) makes every live run foreign, and that is a broken watcher, not a death.
        [ "$FOREIGN" = 0 ] || DETAIL="$FOREIGN run(s) in this window belong to another session"
        return
    fi
    d="$RUNDIR_PATH"
    RUNDIR="${d##*/}"

    # `cleanup` is written by the EXIT trap on EVERY watchdog exit — success, bail, or an
    # external kill. Across 286 archived logs it appears in 286 while `complete` appears in 246,
    # and 36 of the runs carrying it have neither `final` nor `output.txt`. So `cleanup` says
    # "it stopped"; only its exit code says whether it worked.
    rc=""
    wl="$d/watchdog.log"
    if [ -f "$wl" ]; then
        while IFS= read -r line; do
            case "$line" in *'"event":"cleanup"'*) ;; *) continue ;; esac
            [[ "$line" =~ \"exit_code\":[[:space:]]*(-?[0-9]+) ]] && rc="${BASH_REMATCH[1]}"
        done < "$wl"
    fi

    # Root first, but only when NON-EMPTY (-s, not -f): gemini-exec pre-creates a zero-byte
    # output.txt at launch, and on bail the only readable text can sit under final/.
    out="$d/output.txt"; [ -s "$out" ] || out="$d/final/output.txt"
    has_out=0
    [ -s "$out" ] && has_out=1

    # Both terminal branches below need freshness now, so resolve it before either.
    newest_mtime "$d"
    # NOW is stamped once per evaluation, so a run still writing while we walk the roster can
    # carry an mtime past it. The classification is unaffected, but a negative duration on the
    # row reads to an LLM orchestrator as a broken watcher.
    QUIET=$(( NOW - NEWEST )); [ "$QUIET" -lt 0 ] && QUIET=0
    printf -v LAST '%(%H:%M:%S)T' "$NEWEST"

    if [ -n "$rc" ]; then
        # Supervised: the watchdog recorded its own exit, so rc is the authority.
        if [ "$rc" != 0 ]; then
            STATUS=FAILED
            if [ -f "$d/watchdog.exit" ] &&
               [[ "$(cat "$d/watchdog.exit" 2>/dev/null)" =~ \"reason\":[[:space:]]*\"([a-z_]+)\" ]]; then
                DETAIL="${BASH_REMATCH[1]}"
            fi
            return
        fi
        [ "$has_out" = 1 ] && { STATUS=DONE; return; }
        # rc=0 with nothing to read is usually not a failure — it is the extraction window.
        # Declaring FAILED inside it discards a finished review, and design review's failure
        # path never re-dispatches, so the loss is permanent. Let the window close first.
        if [ "$QUIET" -gt "$SETTLE_SEC" ]; then
            STATUS=FAILED; DETAIL="exit 0, no output.txt ${SETTLE_SEC}s after the last write"
        else
            STATUS=RUN
        fi
        return
    fi

    # Unsupervised: nothing recorded an exit, and a non-empty output.txt is NOT by itself
    # finalization — gemini-exec appends to it inside the stream loop, so it goes non-empty
    # seconds after launch and a live run would read DONE. All three *-exec skills write
    # report.md only after that loop ends, which makes it the positive stop signal. The
    # stall-threshold fallback keeps a run whose report was skipped from hanging in RUN.
    if [ ! -f "$wl" ] && [ "$has_out" = 1 ] &&
       { [ -s "$d/report.md" ] || [ "$QUIET" -gt "$STALL_SEC" ]; }; then
        STATUS=DONE
        return
    fi

    if [ "$QUIET" -gt "$STALL_SEC" ]; then STATUS=SILENT; else STATUS=RUN; fi
}

evaluate() {
    local i entry row
    printf -v NOW '%(%s)T' -1
    ROWS=""
    for i in "${!ROSTER[@]}"; do
        entry="${ROSTER[$i]}"
        classify "$entry"
        STATUSES[$i]="$STATUS"
        row="$(printf '%-8s %-26s %s' "$STATUS" "$entry" "${RUNDIR:-—}")"
        case "$STATUS" in
            SILENT)  row="$row  quiet=${QUIET}s last=$LAST"
                     [ "${NEWEST_FROM_DIR:-0}" = 1 ] && row="$row  (no stream file — quiet measured from the run dir's mtime)" ;;
            RUN)     [ -n "$QUIET" ] && row="$row  quiet=${QUIET}s" ;;
            FAILED)  [ -n "$DETAIL" ] && row="$row  $DETAIL" ;;
            MISSING) [ -n "$DETAIL" ] && row="$row  $DETAIL" ;;
        esac
        ROWS="$ROWS$row"$'\n'
    done
}

# The baseline is virtual: every roster entry is assumed RUN, so "what changed" is simply
# "what is not RUN". Establishing the baseline from the first evaluation instead would absorb a
# run that was ALREADY dead when the watcher started — and the watcher restarts after every
# event, so that reproduces the original blindness on every restart.
transitions() {
    local i out=""
    for i in "${!ROSTER[@]}"; do
        [ "${STATUSES[$i]}" = "RUN" ] && continue
        out="$out, ${ROSTER[$i]} RUN→${STATUSES[$i]}"
    done
    printf '%s' "${out#, }"
}

all_done() { local s; for s in "${STATUSES[@]}"; do [ "$s" = DONE ] || return 1; done; return 0; }
any_run()  { local s; for s in "${STATUSES[@]}"; do [ "$s" = RUN ] && return 0; done; return 1; }
any_moved() { local s; for s in "${STATUSES[@]}"; do [ "$s" = RUN ] || return 0; done; return 1; }

emit() { printf '%s\n' "$1"; printf '%s' "$ROWS"; exit 0; }

# Same order, now on a loop: all-done, settle, deadline, change. Because the baseline is
# virtual there is no baseline-establishing pass — the first evaluation and every later one
# run identical logic, and the loop needs no "first time" flag.
while :; do
    evaluate
    all_done && emit "ALL_DONE"
    any_run || emit "SETTLED $(transitions)"
    # The budget can expire on the very tick something moved. DEADLINE still outranks CHANGED —
    # a roster that never stops running must terminate on the budget — but a bare "DEADLINE"
    # summarises a run that just finished as "time ran out", the incident wording this script
    # replaces. Name the transitions when there are any.
    [ "$NOW" -lt "$DEADLINE" ] || { T="$(transitions)"; emit "DEADLINE${T:+ $T}"; }
    any_moved && emit "CHANGED $(transitions)"
    [ "$ONCE" = 0 ] || emit "SNAPSHOT"
    sleep "$POLL_SEC"
done
