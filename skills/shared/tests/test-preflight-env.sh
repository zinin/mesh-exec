#!/usr/bin/env bash
# Regression tests for preflight-env.sh
#
# The probe answers one question for a session that did not configure this machine: what can
# actually be used here? Every verdict exits 0 — a non-zero exit means the probe is broken,
# could not start (64, the bash-4 check) or was interrupted (130/143), never that the
# environment is poor. That contract is the first thing asserted below.
set -u
TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$TESTS_DIR/../preflight-env.sh"

# shellcheck source=lib-yq-doubles.sh
. "$TESTS_DIR/lib-yq-doubles.sh"

# Precondition, not an assertion. Every fixture below drives config-loader.sh, so on a machine
# without a `yq` or `jq` the probe takes the "toolchain missing" branch in ALL of them: the
# universal gates still pass (MISSING is a legal status and every verdict still exits 0), while
# the per-scenario assertions produce a wall of failures that say nothing about the code. One
# loud line beats thirty misleading ones.
for REQ in yq jq; do
    if ! command -v "$REQ" >/dev/null 2>&1; then
        echo "SKIP: $REQ is not installed — this suite drives config-loader.sh, which requires it"
        exit 0
    fi
done

FAIL=0
PASS=0
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

assert_eq() {
    local desc="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        PASS=$((PASS+1)); echo "  PASS: $desc"
    else
        FAIL=$((FAIL+1)); echo "  FAIL: $desc (expected '$expected', got '$actual')"
    fi
}

assert_match() {
    local desc="$1" pattern="$2" actual="$3"
    case "$actual" in
        *"$pattern"*) PASS=$((PASS+1)); echo "  PASS: $desc" ;;
        *) FAIL=$((FAIL+1)); echo "  FAIL: $desc (no '$pattern' in output)" ;;
    esac
}

assert_no_match() {
    local desc="$1" pattern="$2" actual="$3"
    case "$actual" in
        *"$pattern"*) FAIL=$((FAIL+1)); echo "  FAIL: $desc ('$pattern' present in output)" ;;
        *) PASS=$((PASS+1)); echo "  PASS: $desc" ;;
    esac
}

# Status column of a named row ("" when the row is absent).
field() { awk -v n="$1" '$1==n {print $2; exit}' <<<"$2"; }

# Exact entry on a `SUMMARY available:` line. `grok:grok-4.6` is a suffix of
# `native:grok-4.6`; wrapping with ", " makes a substring test tell them apart.
avail_wrap() { printf ', %s, ' "$(grep '^SUMMARY available:' <<<"$1" | sed 's/^SUMMARY available: //')"; }

# Default git shim: answers instantly that there is no 'origin'. Without it every scenario
# below would run a real `git ls-remote` against this repository's remote — up to the git
# budget each, on a network the suite is not testing. Scenarios that DO test git pass their
# own PREFLIGHT_GIT_BIN, which wins because `env` keeps the last assignment.
mkdir -p "$WORK/gitfast"
cat > "$WORK/gitfast/git" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  rev-parse) echo ".git" ;;
  remote)    exit 1 ;;       # no origin configured — resolves without touching the network
  *)         exit 0 ;;
esac
SH
chmod +x "$WORK/gitfast/git"

# Default curl shim: answers 200 instantly. Without it, the moment Task 2's provider probes
# exist, every Task-1 scenario would send the fixture token to the real https://api.z.ai and
# poke 127.0.0.1:11434 with retries — the suite would silently become network-dependent, slow,
# and leak a fixture token outward on every run. Scenarios that test other codes pass their
# own PREFLIGHT_CURL_BIN/PATH, which win because `env` keeps the last assignment.
mkdir -p "$WORK/curlfast"
cat > "$WORK/curlfast/curl" <<'SH'
#!/usr/bin/env bash
echo "200"
exit 0
SH
chmod +x "$WORK/curlfast/curl"

# Fail-fast grok stub. native-models runs `grok models` whenever grok is on PATH,
# which on a developer laptop is a 2s authenticated round-trip (or a 15s timeout)
# in EVERY scenario. Hide the real binary unless the scenario planted a suite-owned
# shim under $WORK (not a farm symlink to the real grok).
mkdir -p "$WORK/grokskip"
cat > "$WORK/grokskip/grok" <<'SH'
#!/usr/bin/env bash
exit 1
SH
chmod +x "$WORK/grokskip/grok"

# A PATH farm: every real PATH entry symlinked into one directory (first occurrence wins, as
# in a real PATH search), minus the binaries named. The only way to make ONE tool genuinely
# absent while the loader still finds yq, jq and the rest — curl, git and codex all live in
# directories full of tools the probe needs, so no subset of the real PATH can drop one alone.
#
# Callers MUST keep $SHIM (or another shim dir) FIRST in any PATH built from a farm: a farm
# carries the REAL curl, and the prechecks resolve `curl` from PATH. Put a farm first and the
# suite starts talking to api.z.ai and to the ollama daemon this machine actually runs.
#
# Defined here, beside the other shared helpers, because two sections use it. PATH_DIRS is
# read here too: as a global set inside one section's block it was a dependency a later edit
# could silently delete, leaving `set -u` to kill the suite mid-run.
IFS=: read -r -a PATH_DIRS <<<"$PATH"
mkfarm() {              # mkfarm <dir> [binary-to-omit ...]
    local dir="$1"; shift
    mkdir -p "$dir"
    local d b
    for d in "${PATH_DIRS[@]}"; do
        [ -n "$d" ] && [ -d "$d" ] && ln -s "$d"/* "$dir/" 2>/dev/null
    done
    for b in "$@"; do rm -f "$dir/$b"; done
}

# Each run gets a private data dir (so the suite never reads the developer's ~/.claude config)
# and a private TMPDIR (so exported env files, which carry tokens, cannot leak into shared /tmp
# and can be counted afterwards). HOME is that dir too, and XDG_CONFIG_HOME is dropped: with no
# config.yaml the loader searches $HOME/.claude/plugins/data for the old claude-mesh config, and
# a case that blanks MESH_CONFIG resolves ${XDG_CONFIG_HOME:-$HOME/.config}/mesh/config.yaml. On
# a developer's machine both are the real config, and the old one's path would decide the hint.
#
# run_probe assigns OUT / ERR / RC / CFG_DIR as globals and is called as a STANDALONE command —
# never as OUT="$(run_probe …)". A command substitution would strand the assignments in its
# subshell and make the exit-code and leak assertions below unfalsifiable: the probe could
# exit 7 and RC would still read 0. Same idiom as test-verify-delegation.sh:43.
#
# THREE PROPERTIES BELOW ARE LOAD-BEARING — do not "simplify" them away:
#   1. stdout and stderr are captured SEPARATELY, never merged with 2>&1. The probe's progress
#      chatter goes to stderr ("probing <provider>…"), and those lines have NF>=2, so merging
#      would feed that chatter to the FINAL GATES at the bottom of this file: the closed-set
#      gate would read a provider name ("zai…") as a status. Task 4's row-order check will
#      have the same exposure once it exists.
#   2. RC=$? stays on the line IMMEDIATELY after the OUT= assignment. Anything in between
#      overwrites $? and makes every exit-code assertion unfalsifiable.
#   3. errf lives in $WORK, never in $CFG_DIR: $CFG_DIR doubles as the probe's TMPDIR and its
#      leftover files are counted to prove exported env files (which carry tokens) were
#      deleted. A stray stderr file there would corrupt that count.
CFG_DIR=""
RC=0
OUT=""
ERR=""
# Accumulators for the FINAL GATES (bottom of file). Per-scenario assertions can only check
# the scenario their author thought about; these two make the universal contracts — closed
# status set, "every verdict exits 0" — hold over EVERY scenario, including ones Tasks 2-4
# have not written yet.
ALL_OUT=""
ALL_ERR=""
BAD_RC=""
PROBE_N=0
run_probe() {           # run_probe <fixture-basename|none> [VAR=value ...]
    local fixture="$1"; shift
    CFG_DIR="$(mktemp -d "$WORK/data-XXXXXX")"
    # A mistyped fixture name must fail loudly: silently leaving $CFG_DIR empty degrades the
    # scenario into "no config", and Tasks 2-4 add scenarios that legitimately expect
    # MISSING/SKIPPED — there the typo would produce a green run that tests nothing.
    if [ "$fixture" != none ] && ! cp "$TESTS_DIR/fixtures/$fixture" "$CFG_DIR/config.yaml"; then
        FAIL=$((FAIL+1))
        echo "  FAIL: cannot stage fixture '$fixture' (missing from $TESTS_DIR/fixtures?)"
    fi
    local errf
    errf="$(mktemp "$WORK/stderr-XXXXXX")"
    local probe_path="$WORK/curlfast:$PATH"
    local -a env_rest=()
    local a grok_bin keep_grok
    for a in "$@"; do
        case "$a" in
            PATH=*) probe_path="${a#PATH=}" ;;
            *) env_rest+=("$a") ;;
        esac
    done
    # Suite-owned grok is a regular file under $WORK (cli-grok, cli-grok-slow). A
    # farm entry is a symlink to the real binary; the developer's grok is neither.
    grok_bin="$(PATH="$probe_path" command -v grok 2>/dev/null || true)"
    keep_grok=0
    case "$grok_bin" in
        "$WORK"/*) [ -L "$grok_bin" ] || keep_grok=1 ;;
    esac
    [ "$keep_grok" = 1 ] || [ -z "$grok_bin" ] || probe_path="$WORK/grokskip:$probe_path"
    OUT="$(env -u XDG_CONFIG_HOME HOME="$CFG_DIR" \
               MESH_CONFIG="$CFG_DIR/config.yaml" XDG_STATE_HOME="$CFG_DIR" TMPDIR="$CFG_DIR" \
               PREFLIGHT_GIT_BIN="$WORK/gitfast/git" \
               PREFLIGHT_CURL_BIN="$WORK/curlfast/curl" PATH="$probe_path" \
               "${env_rest[@]}" bash "$SCRIPT" 2>"$errf")"
    RC=$?
    ERR="$(cat "$errf")"
    rm -f "$errf"
    ALL_OUT="$ALL_OUT$OUT"$'\n'
    ALL_ERR="$ALL_ERR$ERR"$'\n'
    PROBE_N=$((PROBE_N+1))
    [ "$RC" -eq 0 ] || BAD_RC="$BAD_RC #$PROBE_N($fixture rc=$RC)"
}

echo "== Task 1: config detection and static rows =="

run_probe valid-claude-models.yaml
assert_eq   "valid config exits 0"            0    "$RC"
assert_eq   "plugin identity row present"     OK   "$(field plugin "$OUT")"
assert_eq   "valid config -> config OK"       OK   "$(field config "$OUT")"
# Full path, not a bare "/config.yaml" suffix: the detail must name the file the loader
# actually resolved, so an empty `data-dir` cannot satisfy this assertion.
assert_match "config detail names config.yaml" "$CFG_DIR/config.yaml" "$OUT"
assert_eq   "builtin-claude always OK"        OK   "$(field builtin-claude "$OUT")"
assert_eq   "claude catalog -> OK"            OK   "$(field claude-models "$OUT")"
assert_match "catalog lists both aliases"     "opus, fable" "$OUT"
assert_match "native-models row exists" "native-models" "$OUT"
assert_match "claude-cli row exists" "claude-cli" "$OUT"
assert_no_match "does not invent host grok-build from PATH" "host             grok-build" "$OUT"

run_probe none
assert_eq   "missing config exits 0"          0        "$RC"
assert_eq   "missing config -> MISSING"       MISSING  "$(field config "$OUT")"
assert_eq   "built-in claude survives no config" OK    "$(field builtin-claude "$OUT")"
assert_eq   "no config -> catalog SKIPPED"    SKIPPED  "$(field claude-models "$OUT")"
# The table is stdout ONLY. This scenario runs no network probe of any kind (no config ⇒ no
# provider to probe), so the probe has nothing legitimate to say on stderr — now or after
# Tasks 2–4 append their sections. Any output here means diagnostics leaked into the stream
# the reading session parses as rows.
assert_eq   "stdout carries no stderr noise in a local-only run" "" "$ERR"

run_probe invalid-no-providers.yaml
assert_eq   "invalid config exits 0"          0        "$RC"
assert_eq   "invalid config -> INVALID"       INVALID  "$(field config "$OUT")"

# config OK must predict "the orchestrator starts": Step 5.0 validates defaults and runtime
# too, so a config whose models parse but whose defaults: section is broken is INVALID here.
run_probe invalid-defaults-runmode.yaml
assert_eq   "broken defaults -> config INVALID" INVALID "$(field config "$OUT")"

# A dead toolchain must not impersonate a rejected config — the loader dies rc=1 either way,
# but the operator's next move differs (installing a yq that emits JSON vs editing a healthy
# config).
run_probe valid-claude-models.yaml PREFLIGHT_YQ_BIN="$WORK/no-such-yq"
assert_eq   "missing yq exits 0"              0        "$RC"
assert_eq   "missing yq -> its own row"       MISSING  "$(field yq "$OUT")"
assert_eq   "missing yq -> config UNKNOWN, not INVALID" UNKNOWN "$(field config "$OUT")"

# The override the probe checks is not the binary the loader runs: config-loader.sh's
# `require_yq` resolves bare `yq` from PATH. A working override with no `yq` on PATH used to
# satisfy the presence gate and come back as INVALID — a healthy config accused by a probe that
# never opened it.
mkfarm "$WORK/noyq" yq
run_probe valid-claude-models.yaml PATH="$WORK/curlfast:$WORK/noyq" PREFLIGHT_YQ_BIN="$(command -v yq)"
assert_eq   "override without a PATH yq exits 0"                0        "$RC"
assert_eq   "…still reports the yq row"                         MISSING  "$(field yq "$OUT")"
assert_eq   "…and config is UNKNOWN, not INVALID"               UNKNOWN  "$(field config "$OUT")"
assert_match "…naming where the loader looks"                   "where the loader looks" "$OUT"

# The trigger a presence check CANNOT catch, and the one operators actually hit: `apt install yq`
# on Debian and `brew install yq` on macOS both deliver Go-yq. It IS present under the name the
# loader looks for, and the loader now USES it — so a working Go-yq must come back as a working
# environment, not as a verdict about the config.
mkyq_go "$WORK/goyq"
run_probe valid-claude-models.yaml PATH="$WORK/goyq:$WORK/curlfast:$WORK/noyq"
assert_eq   "Go-yq exits 0"                            0    "$RC"
assert_eq   "Go-yq -> config OK"                       OK   "$(field config "$OUT")"
# The one place the yq row can be pinned to the tool that PRODUCED it rather than merely
# proved non-empty: on the happy path the banner belongs to whatever yq the machine has, but
# here the suite authors it (lib-yq-doubles.sh), so a substring is both stable and strong.
# Without this, `row "$canon" OK "present"` — no --version call at all — passes every other
# assertion about the row.
assert_match "…and the yq row names the flavour it found" "mikefarah" "$OUT"
assert_no_match "…and nothing claims a flavour mismatch" "flavor mismatch" "$OUT"
assert_no_match "…and nobody is sent to install a different yq" "pipx install yq" "$OUT"

# A yq that is present, is used, and still cannot do the job. The loader dies rc=1 exactly as a
# rejected config does, so only the routing by cause keeps a healthy config.yaml from being
# blamed — and this scenario is what keeps the probe's signature match in step with the
# loader's own wording.
mkyq_nojson "$WORK/nojsonyq"
run_probe valid-claude-models.yaml PATH="$WORK/nojsonyq:$WORK/curlfast:$WORK/noyq"
assert_eq   "unusable yq exits 0"                          0        "$RC"
assert_eq   "unusable yq -> config UNKNOWN, not INVALID"   UNKNOWN  "$(field config "$OUT")"
assert_match "…and the detail names the tool"              "cannot produce JSON" "$OUT"
assert_match "…and the hint names both flavours"           "Go-yq v4+"      "$OUT"
assert_match "…and says the config was never read"         "was never read" "$OUT"

# The other toolchain die, and the one a version gate would have missed: a yq that DOES emit
# JSON but resolves YAML 1.1. The fixture is the only one whose scalars diverge between the two
# schemas — with any other config the loader is right to accept this binary.
if have_pyyaml; then
    mkyq_yaml11 "$WORK/y11yq"
    run_probe valid-claude-models-level-off.yaml PATH="$WORK/y11yq:$WORK/curlfast:$WORK/noyq"
    assert_eq   "YAML-1.1 yq exits 0"                      0        "$RC"
    assert_eq   "YAML-1.1 yq -> config UNKNOWN"            UNKNOWN  "$(field config "$OUT")"
    assert_match "…named as a resolver, not as a bad config" "mis-resolves" "$OUT"
    assert_no_match "…and the user is not told to quote a correct value" \
        "must be a string (got boolean)" "$OUT"
else
    echo "  SKIP: python3 has no PyYAML — the YAML-1.1 preflight scenario cannot run"
fi

# The third way the loader can die before it has read anything: it cannot create the snapshot
# file at all. TMPDIR is the fault there, not config.yaml, and this file already has a `tmpfile`
# cause for exactly that class — its own mktemp_or_fail guards use it. Without an arm for the
# loader's wording these dies fall through to the routing's `*)` and the probe answers INVALID,
# accusing a file the loader never opened: the impersonation the routing exists to prevent.
# The double fails ONLY the loader's snapshot template, so preflight's own mktemp_or_fail — a
# bare `mktemp`, no template — still works and the scenario stays about the loader.
mkdir -p "$WORK/mktempshim"
MKTEMP_REAL="$(command -v mktemp)"   # resolved BEFORE the shim is on PATH, or the shim recurses
cat > "$WORK/mktempshim/mktemp" <<SH
#!/usr/bin/env bash
for a in "\$@"; do case "\$a" in mesh-cfg-*) exit 1 ;; esac; done
exec $MKTEMP_REAL "\$@"
SH
chmod +x "$WORK/mktempshim/mktemp"
run_probe valid-claude-models.yaml PATH="$WORK/mktempshim:$WORK/curlfast:$PATH"
assert_eq   "a snapshot that cannot be created exits 0"       0        "$RC"
assert_eq   "…-> config UNKNOWN, not INVALID"                 UNKNOWN  "$(field config "$OUT")"
assert_match "…and the detail is the loader's own sentence"   "mktemp failed" "$OUT"
assert_match "…and the hint sends the operator to TMPDIR"     "make TMPDIR writable" "$OUT"
assert_match "…and says the config was never read"            "was never read" "$OUT"

# toolchain_row used to print nothing at all on success, so the table said nothing about which
# yq was in play. With both flavors accepted that is a real variable — it decides the transcode
# form and the loader's speed — and "what can actually be used here" is the question this probe
# exists to answer.
run_probe valid-claude-models.yaml
assert_eq   "a usable yq gets its own OK row"  OK  "$(field yq "$OUT")"
assert_eq   "…and so does jq"                  OK  "$(field jq "$OUT")"
# Not assert_match on the banner: a real one carries parentheses and slashes, and the row must
# be proved NON-EMPTY rather than proved to contain the word "yq", which its own name supplies.
YQ_ROW_DETAIL="$(awk '$1=="yq"{ $1=""; $2=""; sub(/^ +/,""); print; exit }' <<<"$OUT")"
if [ -n "$YQ_ROW_DETAIL" ]; then
    PASS=$((PASS+1)); echo "  PASS: the yq row carries a version banner ($YQ_ROW_DETAIL)"
else
    FAIL=$((FAIL+1)); echo "  FAIL: the yq row has no detail column"
fi

# The OTHER way to reach UNKNOWN, and the one that looked like a rejected config until it was
# guarded: with an unwritable TMPDIR the probe cannot create the file that catches the loader's
# stderr, `cmd 2>""` fails on the redirect alone, and the row read `INVALID` with an EMPTY
# detail — a healthy config.yaml accused of being malformed by a probe that never opened it,
# with nothing printed for the operator to act on. The fixture is deliberately the valid one:
# every claim on this table must come from the environment, never from the config.
run_probe valid-claude-models.yaml TMPDIR="$WORK/no-such-tmpdir"
assert_eq   "unwritable TMPDIR exits 0"       0        "$RC"
assert_eq   "unwritable TMPDIR -> config UNKNOWN, not INVALID" UNKNOWN "$(field config "$OUT")"
# An UNKNOWN whose detail is empty is the defect restated, not the fix: the whole point is that
# the reader learns WHICH of the two UNKNOWN causes happened without leaving the table.
assert_match "…and the detail names the real cause"  "TMPDIR" "$OUT"
assert_no_match "…without blaming the config file"   "INVALID" "$OUT"
# mktemp, the failed redirect and `head -1 ""` each printed their own complaint here. stdout is
# the report and stderr is probe chatter; raw tool diagnostics belong to neither. (The final
# gate at the bottom enforces this over every scenario — these two name the regression.)
assert_no_match "…and mktemp does not complain on stderr" "mktemp:" "$ERR"
assert_no_match "…nor does head"                          "head:"   "$ERR"
assert_eq   "…leaving stderr silent in a run that probes nothing" "" "$ERR"

# A broken claude: section is INVALID with the validator's reason — mesh-review refuses to
# start on this same read, so "no catalog" (MISSING) would be a lie.
run_probe invalid-claude-scalar.yaml
assert_eq   "broken claude section -> INVALID" INVALID "$(field claude-models "$OUT")"

run_probe valid-full.yaml
assert_eq   "no claude section -> MISSING"    MISSING  "$(field claude-models "$OUT")"

echo "== Task 2: provider probes =="

# One shim stands in for curl everywhere, and it has to be faithful in two different ways,
# because the two prechecks read curl differently: token-precheck.sh runs curl WITHOUT -f and
# reads the status code off stdout (401 is a normal exit there), while ollama-precheck.sh runs
# `curl -sf` and reads only curl's own exit status. A shim that always exits 0 would make
# ollama unreachable-proof; one that always fails on 4xx would turn a 401 into "unreachable".
SHIM="$WORK/bin"
mkdir -p "$SHIM"
cat > "$SHIM/curl" <<'SH'
#!/usr/bin/env bash
code="${SHIM_HTTP_CODE:-200}"
fail_on_http=0
for a in "$@"; do case "$a" in -sf|-f|--fail) fail_on_http=1 ;; esac; done
# SHIM_TAGS_CODE, when set, applies to /api/tags ONLY. That path is the only way to reach
# ollama-precheck.sh's rc=5 ("daemon up, tags errored") without a real daemon: the daemon
# ping and the tags read differ by URL alone.
for a in "$@"; do case "$a" in */api/tags) code="${SHIM_TAGS_CODE:-$code}" ;; esac; done
[ "$code" = "000" ] && exit 7                                    # curl itself failed
[ "$fail_on_http" = 1 ] && [ "$code" -ge 400 ] && exit 22        # what -f does on 4xx/5xx
echo "$code"
exit 0
SH
chmod +x "$SHIM/curl"

# A PATH that genuinely has no curl but still has everything the loader needs (yq, jq, …).
mkfarm "$WORK/nocurl" curl

run_probe valid-full.yaml PREFLIGHT_CURL_BIN="$SHIM/curl" PATH="$SHIM:$PATH" SHIM_HTTP_CODE=200
assert_eq "reachable provider -> OK"          OK   "$(field provider:zai "$OUT")"
assert_eq "ollama-kind provider probed too"   OK   "$(field provider:ollama "$OUT")"
assert_eq "probing providers still exits 0"   0    "$RC"
assert_match "detail names the endpoint"      "https://api.z.ai" "$OUT"

# Three models, two providers: the probe runs once per provider, not once per model.
assert_eq "one row per provider" 2 "$(grep -c '^provider:' <<<"$OUT")"

run_probe valid-full.yaml PREFLIGHT_CURL_BIN="$SHIM/curl" PATH="$SHIM:$PATH" SHIM_HTTP_CODE=401
assert_eq "401 -> AUTH-FAILED"                AUTH-FAILED "$(field provider:zai "$OUT")"
assert_match "…and blames the credentials"    "credentials rejected" "$OUT"

# Same status, different kind, different advice: an ollama daemon has no credential to
# reject, so rc=5 there must not send the operator hunting for a token that does not exist.
# Only /api/tags fails here, which is exactly what "daemon up, not signed in" looks like.
run_probe valid-full.yaml PREFLIGHT_CURL_BIN="$SHIM/curl" PATH="$SHIM:$PATH" \
          SHIM_HTTP_CODE=200 SHIM_TAGS_CODE=404
assert_eq "ollama tags failure -> AUTH-FAILED" AUTH-FAILED "$(field provider:ollama "$OUT")"
assert_match "…advises ollama signin"          "ollama signin" "$OUT"
assert_no_match "…and never blames a token"    "credentials rejected" "$OUT"
assert_eq "…while the anthropic-api provider is untouched" OK "$(field provider:zai "$OUT")"

run_probe valid-full.yaml PREFLIGHT_CURL_BIN="$SHIM/curl" PATH="$SHIM:$PATH" SHIM_HTTP_CODE=000
assert_eq "unreachable -> NO-NETWORK"         NO-NETWORK  "$(field provider:zai "$OUT")"

# SKIP_TOKEN_PRECHECK exists so a caller can skip the check. Inherited, it would turn every
# provider row into a false OK — the probe must neutralise it.
run_probe valid-full.yaml PREFLIGHT_CURL_BIN="$SHIM/curl" PATH="$SHIM:$PATH" \
          SHIM_HTTP_CODE=000 SKIP_TOKEN_PRECHECK=1
assert_eq "SKIP_TOKEN_PRECHECK cannot fake OK" NO-NETWORK "$(field provider:zai "$OUT")"

# A copied-but-unedited config: export refuses to hand out a REPLACE_ME token.
run_probe invalid-token-replace-me.yaml PREFLIGHT_CURL_BIN="$SHIM/curl" PATH="$SHIM:$PATH"
assert_match "REPLACE_ME reported as a config gap, not a network verdict" "token not configured" "$OUT"

# runtime: is gated at the config row (config OK = the orchestrator starts), so a broken
# runtime can no longer masquerade as a per-provider token gap. probe_provider keeps its
# UNKNOWN/export-refused branch as defence-in-depth (mktemp failure, races, future loader
# changes) — no fixture can reach it any more, and that is the point.
run_probe invalid-runtime-runmode.yaml PREFLIGHT_CURL_BIN="$SHIM/curl" PATH="$SHIM:$PATH"
assert_eq "broken runtime -> config INVALID"  INVALID "$(field config "$OUT")"
assert_no_match "…not blamed on any token"    "token not configured" "$OUT"

# No curl (the probe's own binary): prechecks are not invoked at all — UNKNOWN, not a fake
# network verdict. No PATH surgery needed: the gate is HAVE_CURL, not the prechecks' lookup.
run_probe valid-full.yaml PREFLIGHT_CURL_BIN="$WORK/no-such-curl"
assert_eq "no curl -> provider UNKNOWN"       UNKNOWN "$(field provider:zai "$OUT")"

# The other half of the same gate, and the one that fabricates a verdict if it is missing:
# PREFLIGHT_CURL_BIN resolves, but the prechecks look `curl` up on PATH and would not find it.
# token-precheck.sh turns that command-not-found into HTTP 000 -> rc 6 -> NO-NETWORK, an
# endpoint verdict invented out of a missing binary. UNKNOWN is the only honest answer.
run_probe valid-full.yaml PREFLIGHT_CURL_BIN="$SHIM/curl" PATH="$WORK/nocurl"
assert_eq "curl absent from PATH -> its own row" MISSING "$(field curl "$OUT")"
assert_eq "…and provider UNKNOWN, not NO-NETWORK" UNKNOWN "$(field provider:zai "$OUT")"
assert_match "…naming the PATH gap"           "curl on PATH" "$OUT"

# Missing ext-claude prerequisites: endpoint reachability is irrelevant if the executor
# cannot start — provider rows degrade and name the gap.
run_probe valid-full.yaml PREFLIGHT_CURL_BIN="$SHIM/curl" PATH="$SHIM:$PATH" SHIM_HTTP_CODE=200 \
          PREFLIGHT_EXT_DEPS_BINS="bc no-such-ext-tool"
assert_eq "missing ext dep -> its own row"    MISSING "$(field ext-claude-deps "$OUT")"
assert_eq "…and providers degrade"            MISSING "$(field provider:zai "$OUT")"
assert_match "…naming the executor gap"       "ext-claude prerequisites absent" "$OUT"

# Re-runs inside a session: PREFLIGHT_SKIP_NETWORK answers from local facts alone — the
# prechecks are never invoked, so this must hold even with a broken shim on PATH.
run_probe valid-full.yaml PREFLIGHT_CURL_BIN="$SHIM/curl" PATH="$SHIM:$PATH" \
          SHIM_HTTP_CODE=000 PREFLIGHT_SKIP_NETWORK=1
assert_eq "skip-network -> provider UNKNOWN"  UNKNOWN "$(field provider:zai "$OUT")"
assert_match "…and says the network was skipped" "skipped by PREFLIGHT_SKIP_NETWORK" "$OUT"

# Secrets: the token from the fixture must not appear anywhere, and no exported env file
# may survive the run (TMPDIR is private to this run, so a leftover is visible).
# BOTH streams are checked: this section is the first to write to stderr ("probing zai…"),
# so "no secret reaches stdout or stderr" needs an assertion on $ERR too — a precheck that
# stopped discarding its diagnosis would leak the token there while $OUT stayed clean.
run_probe valid-full.yaml PREFLIGHT_CURL_BIN="$SHIM/curl" PATH="$SHIM:$PATH" SHIM_HTTP_CODE=200
assert_no_match "provider token never printed"        "tkn-zai" "$OUT"
assert_no_match "…and never reaches stderr either"    "tkn-zai" "$ERR"
LEFT="$(find "$CFG_DIR" -name 'mesh-env-*' 2>/dev/null | wc -l | tr -d ' ')"
assert_eq "exported env files removed" 0 "$LEFT"

echo "== Task 3: CLI and git rows =="

# codex and gemini ship via npm, so a developer's PATH very likely has both — and then
# "section present, CLI absent" could never be reached and the suite would be reporting the
# laptop instead of the fixture.
mkfarm "$WORK/nocli" codex gemini grok
# `timeout` is GNU-only: absent on a stock macOS, which is exactly the unconfigured machine
# this probe exists for.
mkfarm "$WORK/notimeout" timeout
mkfarm "$WORK/nopy3" python3

# Both CLIs, shimmed. EVERY scenario below pins the CLI's presence or absence explicitly —
# neither verdict may depend on what the machine running the suite happens to have installed.
# The two directions need separate directories because they are needed in the same scenarios
# for different tools: $SHIM/codex is wanted from here to the end of the section, while gemini
# must be ABSENT from the valid-codex-gemini.yaml runs further down (which put $WORK/nocli
# after $SHIM — a $SHIM/gemini would shadow the farm's deletion and silently un-test that).
cat > "$SHIM/codex" <<'SH'
#!/usr/bin/env bash
echo "codex 0.0.0-test"
SH
chmod +x "$SHIM/codex"
mkdir -p "$WORK/cli-gemini"
cat > "$WORK/cli-gemini/gemini" <<'SH'
#!/usr/bin/env bash
echo "gemini 0.0.0-test"
SH
chmod +x "$WORK/cli-gemini/gemini"

# valid-full.yaml has no codex:/gemini: sections. The selection UI hides those reviewers on
# exactly that condition, so the row must say "config", not "network", whatever is on PATH.
# Both CLIs are on PATH here ON PURPOSE and by shim, not by luck: the section gate is the only
# thing that can produce MISSING, on this machine and on a bare CI box alike.
run_probe valid-full.yaml PREFLIGHT_CURL_BIN="$SHIM/curl" PATH="$SHIM:$WORK/cli-gemini:$PATH"
assert_eq   "no codex section -> MISSING"      MISSING "$(field codex "$OUT")"
assert_match "and says the codex section is absent" "no codex: section" "$OUT"
assert_eq   "no gemini section -> MISSING"     MISSING "$(field gemini "$OUT")"

# A section that exists but that the typed getter rejects: the UI would offer it and then die
# on get-codex — the probe must say INVALID first, before any CLI or network claim. Same
# reason for the shimmed CLIs: INVALID must outrank a perfectly healthy binary.
run_probe broken-codex-valid-gemini.yaml PREFLIGHT_CURL_BIN="$SHIM/curl" \
          PATH="$SHIM:$WORK/cli-gemini:$PATH" SHIM_HTTP_CODE=200
assert_eq   "malformed codex section -> INVALID" INVALID "$(field codex "$OUT")"
assert_match "…with the validator's own reason"  "codex.model" "$OUT"

# With a valid section present, the CLI must exist on PATH before the network is consulted.
run_probe valid-codex-gemini.yaml PREFLIGHT_CURL_BIN="$SHIM/curl" PATH="$SHIM:$WORK/nocli" SHIM_HTTP_CODE=200
assert_eq   "codex CLI + network -> OK"        OK          "$(field codex "$OUT")"
assert_match "codex verdict marked heuristic"  "heuristic" "$OUT"
assert_eq   "gemini section but no CLI"        MISSING     "$(field gemini "$OUT")"

run_probe valid-codex-gemini.yaml PREFLIGHT_CURL_BIN="$SHIM/curl" PATH="$SHIM:$WORK/nocli" SHIM_HTTP_CODE=000
assert_eq   "codex CLI, no network -> NO-NETWORK" NO-NETWORK "$(field codex "$OUT")"

# A curl that exits 0 and prints nothing: %{http_code} is unparseable, so there IS no status
# code and no reachability was established. UNKNOWN — the file's other guards (HAVE_CURL, the
# timeout(1) check) all degrade this way, and OK is the one direction that must never be
# reached by accident.
mkdir -p "$WORK/mutecurl"
printf '#!/usr/bin/env bash\nexit 0\n' > "$WORK/mutecurl/curl"
chmod +x "$WORK/mutecurl/curl"
run_probe valid-codex-gemini.yaml PREFLIGHT_CURL_BIN="$WORK/mutecurl/curl" PATH="$SHIM:$WORK/nocli"
assert_eq   "curl exits 0 saying nothing -> UNKNOWN" UNKNOWN "$(field codex "$OUT")"

# curl absent: nothing that needs the network may claim a verdict.
run_probe valid-codex-gemini.yaml PREFLIGHT_CURL_BIN="$WORK/no-such-curl" PATH="$SHIM:$PATH"
assert_eq   "no curl -> codex UNKNOWN"         UNKNOWN "$(field codex "$OUT")"
assert_eq   "no curl -> its own row"           MISSING "$(field curl "$OUT")"
assert_no_match "…and announces no probe it never made" "probing codex" "$ERR"

# --- grok ---------------------------------------------------------------------------------
# Unlike codex and gemini, grok's reachability is probed with the CLI itself: `grok models`
# answers only when the machine has network AND a live login, and the subscription path never
# touches the public api.x.ai an HTTP probe would have to guess at.
mkdir -p "$WORK/cli-grok"
cat > "$WORK/cli-grok/grok" <<'SH'
#!/usr/bin/env bash
# Records EVERY invocation, before any branch. "The flag skipped the probe" is a claim about
# what did NOT run, and no assertion on the report can make it: the skip row and the HTTP
# fallback's row carry the same sentence, so "ran the CLI, then printed the skip message
# anyway" is invisible from stdout. Defaults to /dev/null, so the scenarios that do not set
# GROK_SHIM_LOG are unaffected by it.
printf '%s\n' "$*" >> "${GROK_SHIM_LOG:-/dev/null}"
case "${1:-}" in
  models) [ "${GROK_SHIM_FAIL:-0}" = 1 ] && { echo "not logged in" >&2; exit 1; }
          # List rows (`* slug` / `- slug`) are what list-host-models.sh reads.
          # `Default model: grok-4.6` alone is dropped, and native:<slug> never
          # reaches SUMMARY available.
          if [ "${GROK_SHIM_EMPTY:-0}" = 1 ]; then
            printf '%s\n' \
              'You are logged in with grok.com.' \
              '' \
              'Available models:'
            exit 0
          fi
          printf '%s\n' \
            'You are logged in with grok.com.' \
            '' \
            'Default model: grok-4.6' \
            '' \
            'Available models:' \
            '  * grok-4.6 (default)' \
            '  - grok-4.5' ;;
  *)      exit 0 ;;
esac
SH
chmod +x "$WORK/cli-grok/grok"
GROK_LOG="$WORK/grok-calls.log"

# No grok: section -> MISSING, and the reason says the UI will not offer it.
run_probe valid-full.yaml PREFLIGHT_CURL_BIN="$SHIM/curl" PATH="$SHIM:$WORK/cli-grok:$PATH"
assert_eq   "no grok section -> MISSING"    MISSING "$(field grok "$OUT")"
assert_match "and says the grok section is absent" "no grok: section" "$OUT"

# Section present, CLI present, `grok models` answers -> OK, and the catalog reaches the summary.
: > "$GROK_LOG"
run_probe valid-grok.yaml PREFLIGHT_CURL_BIN="$SHIM/curl" PATH="$WORK/cli-grok:$SHIM:$PATH" \
          GROK_SHIM_LOG="$GROK_LOG"
assert_eq   "grok CLI + login -> OK"        OK "$(field grok "$OUT")"
assert_match "summary names each grok model" "grok:grok-4.6" "$OUT"
assert_match "…including the second one"     "grok:grok-4.5" "$OUT"
# The POSITIVE CONTROL for the skip-network scenario below, which asserts this same log is
# empty: an unset GROK_SHIM_LOG, a shim that never records, or a PATH that finds a different
# grok would all satisfy "empty" for the wrong reason. Here the identical plumbing must record
# exactly one `models` call, so "empty" there can only mean the probe was not run.
# ONE call, not two: the native-models row is derived from the health probe's captured
# stdout rather than probing again. Two calls cost two authenticated round-trips and up to
# 2x CLI_TIMEOUT, and made the two rows independent observations of one fact — free to
# disagree if a login expired between them.
assert_eq   "…and the CLI was invoked as \`grok models\` exactly ONCE" \
    "models" "$(cat "$GROK_LOG")"
assert_eq   "…and native-models is OK from that same single listing" OK "$(field native-models "$OUT")"
assert_match "native listing reaches available as native:<slug>" \
    ", native:grok-4.6, " "$(avail_wrap "$OUT")"
assert_match "…and grok:<slug> is a different reviewer" \
    ", grok:grok-4.6, " "$(avail_wrap "$OUT")"

# grok models answers but parses to zero slugs → native-models is not OK, and
# SUMMARY must not advertise a selectable native reviewer.
run_probe valid-grok.yaml PREFLIGHT_CURL_BIN="$SHIM/curl" PATH="$WORK/cli-grok:$SHIM:$PATH" \
          GROK_SHIM_EMPTY=1
assert_eq   "empty grok models listing -> native-models SKIP" SKIP "$(field native-models "$OUT")"
assert_no_match "empty listing does not advertise native in available" \
    ", native," "$(avail_wrap "$OUT")"
assert_no_match "…nor a native:<slug>" \
    ", native:" "$(avail_wrap "$OUT")"

# The CLI is there but not logged in -> NO-NETWORK, and the hint names the fix.
run_probe valid-grok.yaml PREFLIGHT_CURL_BIN="$SHIM/curl" PATH="$WORK/cli-grok:$SHIM:$PATH" GROK_SHIM_FAIL=1
assert_eq   "grok models fails -> NO-NETWORK" NO-NETWORK "$(field grok "$OUT")"
assert_match "…and suggests logging in"       "grok login" "$OUT"
assert_eq   "…and native-models is SKIP, not a crash" SKIP "$(field native-models "$OUT")"
assert_match "…whose detail points at the grok row instead of a second probe" \
    "see the grok row" "$OUT"
assert_eq   "…and the CLI was NOT invoked a second time after the failure" \
    "models" "$(cat "$GROK_LOG")"

# A machine without python3 must not be told a grok reviewer is available. grok-exec STOPs on
# shared/extract-result.py — the only one of the three CLI engines that does — while `bc` only
# WARNs there and the `claude` binary is never invoked, so the gate is on python3 alone and not
# on the composite EXT_DEPS_MISSING. It matters because commands/*-fresh-session.md call
# `SUMMARY available` the eligibility decision in so many words, and `default` is
# non-interactive: nobody is there to cross-read the deps row and infer the dispatch will die.
# The grok ROW stays OK on purpose — the CLI really is installed and really did answer; it is
# the SUMMARY, the line that decides, which must not advertise it.
: > "$GROK_LOG"
run_probe valid-grok.yaml PREFLIGHT_CURL_BIN="$SHIM/curl" PATH="$WORK/cli-grok:$SHIM:$WORK/nopy3" \
          GROK_SHIM_LOG="$GROK_LOG"
assert_eq   "no python3 -> the grok row still reads OK" OK "$(field grok "$OUT")"
assert_match "…but SUMMARY withdraws it, naming why" "grok (python3 missing" "$OUT"
# The positive half FIRST, so the negative one below cannot pass against an empty haystack —
# a grep that matched nothing would satisfy assert_no_match for the wrong reason, which this
# suite has been bitten by before.
assert_match "…the available line is present and non-empty" "claude" "$(grep '^SUMMARY available' <<<"$OUT")"
# `grok:grok-4.6` is a suffix of `native:grok-4.6` — exact entries only.
assert_no_match "…and no grok model is advertised as available" \
    ", grok:grok-4.6, " "$(avail_wrap "$OUT")"
assert_match "…while the deps row names grok, not ext-claude alone" "grok-exec STOPs without python3" "$OUT"

# An UNUSABLE PREFLIGHT_CLI_TIMEOUT must not be able to invent a verdict. The budget is pasted
# straight into `timeout "$CLI_TIMEOUT" $5`, so before it joined the normalisation block above
# HTTP_TIMEOUT and GIT_TIMEOUT, `--help` made timeout(1) print its usage and exit 0 WITHOUT
# running the probe — and the row then read `grok OK ... answered` about a CLI that was never
# contacted, putting grok into SUMMARY available, which is exactly what the *-fresh-session
# commands read to decide whether `default` is safe. The same three shapes the comment above
# the normalisation block already records for PREFLIGHT_GIT_TIMEOUT. The shim FAILS throughout,
# so OK is only reachable by not running it; the invocation log discriminates "probe ran and
# failed" from "probe never ran", which the row text alone cannot.
for _bad in --help abc 0; do
    : > "$GROK_LOG"          # per-iteration, or the log accumulates and iteration 2 fails
    run_probe valid-grok.yaml PREFLIGHT_CURL_BIN="$SHIM/curl" PATH="$WORK/cli-grok:$SHIM:$PATH" \
              GROK_SHIM_FAIL=1 GROK_SHIM_LOG="$GROK_LOG" PREFLIGHT_CLI_TIMEOUT="$_bad"
    assert_eq "unusable PREFLIGHT_CLI_TIMEOUT=$_bad -> still NO-NETWORK" NO-NETWORK "$(field grok "$OUT")"
    # ONE call: the probe ran (that is what this distinguishes from "never ran"), and a probe
    # that ran and failed means native-models does not ask the CLI a second time.
    assert_eq "…and the probe really was run under $_bad" \
        "models" "$(cat "$GROK_LOG")"
done
unset _bad

# Section present, binary absent -> MISSING (the section gate passes, the CLI gate does not).
run_probe valid-grok.yaml PREFLIGHT_CURL_BIN="$SHIM/curl" PATH="$SHIM:$WORK/nocli"
assert_eq   "grok binary absent -> MISSING"  MISSING "$(field grok "$OUT")"
# native-models lists host slugs via `grok models`. No grok on PATH is SKIP, never a
# non-zero exit — the probe still answers, it just has nothing to list.
assert_eq   "no grok -> native-models SKIP"  SKIP "$(field native-models "$OUT")"
assert_eq   "…and the probe still exits 0"   0    "$RC"

# A malformed grok: section is INVALID before any CLI or network claim — same order as codex.
run_probe broken-grok-valid-codex.yaml PREFLIGHT_CURL_BIN="$SHIM/curl" \
          PATH="$WORK/cli-grok:$SHIM:$PATH" SHIM_HTTP_CODE=200
assert_eq   "malformed grok section -> INVALID" INVALID "$(field grok "$OUT")"
assert_match "…with the validator's own reason" "grok.models" "$OUT"

# The REFERENCED broken catalog — config.example.yaml's own shape with one typo, and the case
# the fixture above cannot reach: there `builtin: [codex]` never mentions grok. Here BOTH
# presets do. The invariant under test is the whole point of the lazy check: CONFIG stays OK
# and every other row keeps its own verdict, while grok alone reports INVALID. Until the
# loader degraded instead of dying, this printed `config INVALID` with SKIPPED on every row —
# claude and codex included — off one typo in a user-owned file, which is the `ultra`
# incident's shape. The defaults line is asserted SCOPED: an unscoped "no grok" over the whole
# report is false by construction, because the grok row itself says grok.
run_probe broken-grok-referenced.yaml PREFLIGHT_CURL_BIN="$SHIM/curl" \
          PATH="$WORK/cli-grok:$SHIM:$PATH" SHIM_HTTP_CODE=200
assert_eq   "referenced broken grok catalog -> config stays OK" OK "$(field config "$OUT")"
assert_eq   "…and grok alone is INVALID"        INVALID "$(field grok "$OUT")"
assert_eq   "…claude-models keeps its verdict"  OK      "$(field claude-models "$OUT")"
# NB: $OUT holds the report TEXT, not a path — grep it with a here-string. `grep … "$OUT"`
# reads it as a FILENAME, and the resulting error message becomes the haystack: the no_match
# below then passes against grep's own "No such file or directory", asserting nothing.
assert_match "…claude survives into available"  "claude:opus" "$(grep 'SUMMARY available' <<<"$OUT")"
assert_no_match "…and the preset dispatches no grok" "grok" "$(grep 'SUMMARY defaults code_review' <<<"$OUT")"

# PREFLIGHT_SKIP_NETWORK must skip the command probe too, not run it silently. TWO assertions
# are needed and neither is redundant. The message is matched against the grok ROW, not the
# whole report: provider:zai and git-remote print that same sentence in this very scenario, so
# an unscoped substring test is green even when the grok row says nothing of the kind — and it
# WAS, against a build with no grok row at all. The shim's log is the other half: it separates
# "skipped" from "ran the CLI, then printed the skip message anyway", which stdout cannot.
: > "$GROK_LOG"
run_probe valid-grok.yaml PREFLIGHT_SKIP_NETWORK=1 PATH="$WORK/cli-grok:$SHIM:$PATH" \
          GROK_SHIM_LOG="$GROK_LOG"
assert_eq   "skip-network -> UNKNOWN"        UNKNOWN "$(field grok "$OUT")"
assert_match "…named as the flag's doing"    "skipped by PREFLIGHT_SKIP_NETWORK" "$(grep '^grok' <<<"$OUT")"
assert_eq   "…and the CLI was never invoked" "" "$(cat "$GROK_LOG")"

# No timeout(1): `timeout … grok models` would exit 127 and the row would read NO-NETWORK — a
# not-logged-in accusation fabricated out of a missing binary, on a machine that is online and
# logged in. Exactly the defect the git-remote gate below exists to prevent, and the same farm.
run_probe valid-grok.yaml PREFLIGHT_CURL_BIN="$SHIM/curl" PATH="$WORK/cli-grok:$SHIM:$WORK/notimeout"
assert_eq   "no timeout(1) -> grok UNKNOWN, not NO-NETWORK" UNKNOWN "$(field grok "$OUT")"
assert_match "…naming the missing binary"                   "timeout" "$(grep '^grok' <<<"$OUT")"

# The command probe has its OWN budget, PREFLIGHT_CLI_TIMEOUT, and does not share the HTTP one.
# `grok models` is a full CLI start plus an authenticated round-trip — measured 1.83-2.30s on
# grok 1.0.13, against 1.0-1.2s when the design wrote the shared 5s budget around "roughly
# fourfold headroom" — while codex's and gemini's probes are a curl. A slow-but-healthy CLI
# timing out prints "no network, or not logged in" as a fact and drops grok from SUMMARY, which
# the *-fresh-session commands read to decide whether `default` is safe: a false negative
# feeding an automatic decision.
mkdir -p "$WORK/cli-grok-slow"
cat > "$WORK/cli-grok-slow/grok" <<'SH'
#!/usr/bin/env bash
# Slower than a 1s budget, far inside the 15s default. Nothing here depends on the real CLI.
case "${1:-}" in
  models) sleep 2; printf 'You are logged in with grok.com.\n\nDefault model: grok-4.6\n' ;;
  *)      exit 0 ;;
esac
SH
chmod +x "$WORK/cli-grok-slow/grok"

# THE SEPARATION, and the assertion that would have been red before the split: squeezing the
# HTTP budget must no longer touch the grok row. Measured on the pre-fix build, the very same
# invocation produced `grok NO-NETWORK`.
run_probe valid-grok.yaml PREFLIGHT_CURL_BIN="$SHIM/curl" PATH="$WORK/cli-grok-slow:$SHIM:$PATH" \
          PREFLIGHT_HTTP_TIMEOUT=1
assert_eq   "a squeezed HTTP budget no longer fails the grok row" OK "$(field grok "$OUT")"

# …and the CLI budget does govern it.
run_probe valid-grok.yaml PREFLIGHT_CURL_BIN="$SHIM/curl" PATH="$WORK/cli-grok-slow:$SHIM:$PATH" \
          PREFLIGHT_CLI_TIMEOUT=1
assert_eq   "PREFLIGHT_CLI_TIMEOUT does govern the command probe" NO-NETWORK "$(field grok "$OUT")"
# Scoped to the grok ROW: provider:zai and git-remote print their own sentences in this report.
assert_match "…and the row names the knob to turn" "PREFLIGHT_CLI_TIMEOUT" "$(grep '^grok' <<<"$OUT")"
assert_match "…reporting the budget it actually used" "after 1s" "$(grep '^grok' <<<"$OUT")"

# git: absent binary is MISSING, and a hanging remote is NO-NETWORK rather than a hang.
run_probe none PREFLIGHT_GIT_BIN="$WORK/no-such-git"
assert_eq   "no git -> MISSING"                MISSING "$(field git-remote "$OUT")"
assert_eq   "missing git still exits 0"        0       "$RC"
# Same run, the config gate: with no config there is no section to read, so a CLI row must say
# SKIPPED rather than blame the CLI or the network. PATH here is the real one — both binaries
# are present, so only the gate order can produce this verdict.
assert_eq   "no config -> codex SKIPPED"       SKIPPED "$(field codex "$OUT")"
assert_eq   "no config -> gemini SKIPPED"      SKIPPED "$(field gemini "$OUT")"
assert_eq   "no config -> grok SKIPPED"        SKIPPED "$(field grok "$OUT")"

# Not a repository at all: still a local fact, never a network verdict.
mkdir -p "$WORK/gitnorepo"
cat > "$WORK/gitnorepo/git" <<'SH'
#!/usr/bin/env bash
exit 1
SH
chmod +x "$WORK/gitnorepo/git"
run_probe none PREFLIGHT_GIT_BIN="$WORK/gitnorepo/git"
assert_eq   "not in a repo -> MISSING"         MISSING "$(field git-remote "$OUT")"
assert_match "…and says which local fact"      "not inside a git repository" "$OUT"

# Deliberately NOT in $SHIM: this shim sleeps, and $SHIM is on PATH for every later scenario.
mkdir -p "$WORK/gitshim"
cat > "$WORK/gitshim/git" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  remote)     echo "https://example.invalid/repo.git" ;;   # a remote IS configured
  ls-remote)  sleep 30 ;;                                  # …and it never answers
  *)          exit 0 ;;
esac
SH
chmod +x "$WORK/gitshim/git"
run_probe none PREFLIGHT_GIT_BIN="$WORK/gitshim/git" PREFLIGHT_GIT_TIMEOUT=1
assert_eq   "unreachable remote -> NO-NETWORK" NO-NETWORK "$(field git-remote "$OUT")"

# The only path that yields OK — and the only thing proving the NO-NETWORK above is a verdict
# rather than what that branch always prints.
mkdir -p "$WORK/gitok"
cat > "$WORK/gitok/git" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  remote)     echo "https://example.invalid/repo.git" ;;
  ls-remote)  echo "0000000000000000000000000000000000000000	HEAD" ;;
  *)          exit 0 ;;
esac
SH
chmod +x "$WORK/gitok/git"
run_probe none PREFLIGHT_GIT_BIN="$WORK/gitok/git"
assert_eq   "answering remote -> OK"           OK "$(field git-remote "$OUT")"

# PREFLIGHT_SKIP_NETWORK has to reach every probe this task adds, not just the provider loop:
# the git shim here would sleep 30s and the codex shim is on PATH, so a leaked probe is visible
# both as a wrong verdict and as chatter.
run_probe valid-codex-gemini.yaml PREFLIGHT_CURL_BIN="$SHIM/curl" PATH="$SHIM:$WORK/nocli" \
          PREFLIGHT_GIT_BIN="$WORK/gitshim/git" PREFLIGHT_SKIP_NETWORK=1
assert_eq   "skip-network -> git-remote UNKNOWN" UNKNOWN "$(field git-remote "$OUT")"
assert_eq   "skip-network -> codex UNKNOWN"      UNKNOWN "$(field codex "$OUT")"
assert_no_match "…and no probe is announced"     "probing codex" "$ERR"

# …and it must mean the same thing spelled any other way. A session told "set
# PREFLIGHT_SKIP_NETWORK" writes `true` at least as readily as `1`, and the three consumers of
# this flag do not all test it the same way — one skips on "not 0", two probe on "not 1". A
# truthy value that reaches only some of them is the worst outcome: it skips the cheap probes
# and still spends the git budget on the operator's real remote. Same sleeping shim, so a leak
# shows up as an 8-second stall AND a wrong verdict, and never as an actual request.
run_probe valid-codex-gemini.yaml PREFLIGHT_CURL_BIN="$SHIM/curl" PATH="$SHIM:$WORK/nocli" \
          PREFLIGHT_GIT_BIN="$WORK/gitshim/git" PREFLIGHT_SKIP_NETWORK=true
assert_eq   "truthy skip-network -> git-remote UNKNOWN" UNKNOWN "$(field git-remote "$OUT")"
assert_eq   "…and provider UNKNOWN"                     UNKNOWN "$(field provider:zai "$OUT")"
assert_eq   "…and codex UNKNOWN"                        UNKNOWN "$(field codex "$OUT")"
assert_eq   "…with nothing on stderr at all"            ""      "$ERR"

# No timeout(1): `timeout … ls-remote` would fail with 127 and the row would read NO-NETWORK —
# an endpoint verdict fabricated out of a missing binary, the same defect the curl gate exists
# to prevent. The remote here ANSWERS, so NO-NETWORK could only come from that fabrication.
run_probe none PREFLIGHT_GIT_BIN="$WORK/gitok/git" PREFLIGHT_CURL_BIN="$SHIM/curl" \
          PATH="$SHIM:$WORK/notimeout"
assert_eq   "no timeout(1) -> UNKNOWN, not NO-NETWORK" UNKNOWN "$(field git-remote "$OUT")"
# Scoped to the row, exactly as the grok twin above is: the row NAME `bash-timeout` prints in
# every scenario, so an unscoped match here holds whatever the git-remote row happens to say.
assert_match "…naming the missing binary"              "timeout" "$(grep '^git-remote' <<<"$OUT")"

assert_match "gh row present"        "gh"        "$OUT"
# A substring check that would pass on prose. `field` proves each is a real row; the status
# itself is machine-dependent (gh/glab may or may not be installed), so it is checked for
# membership in the closed set rather than for a fixed value.
for TOOLROW in gh glab; do
    assert_eq "$TOOLROW is a row with a real status" 1 \
        "$(grep -Ec '^(OK|MISSING)$' <<<"$(field "$TOOLROW" "$OUT")")"
done
# No `clipboard` row: nothing in the plugin copies a generated prompt any more — every
# fresh-session generator prints the file path instead — so the row had no reader left, and
# its MISSING advice ("print generated prompts into the chat") said the opposite of what the
# generators now do. `field` is "" for an absent row; a status here means the row came back.
assert_eq "no clipboard row" "" "$(field clipboard "$OUT")"

echo "== Task 4: SUMMARY =="

# THE point of the defaults lines: "is `default` mode safe here" must be a membership check a
# session can do by eye, not a mapping exercise. `defaults_not_available <probe stdout>` echoes
# the entries that fail it; empty means `default` is selectable in that environment.
#
# Whole ENTRIES, split on ", " — never substrings. `claude` is a prefix of `claude:opus` and
# `zai/glm` of a hypothetical `zai/glm-air`, so a substring test false-accepts precisely the
# spellings this check exists to catch.
#
# ONE deliberate exception, and it is NOT a substring rule in disguise: a bare `claude` entry is
# satisfied by any `claude:<model>` entry. When a preset omits claude_models the orchestrator
# really does run exactly one reviewer literally named `claude` (mesh-design-review Step 5.1)
# while the selection UI offers the catalog entries — one reviewer, two spellings. The reverse
# does NOT hold, and all three rules are pinned by the synthetic checks below.
summary_entries() {             # one entry per line from a `SUMMARY …: a, b, c` line
    # ${1#SUMMARY *: } takes the SHORTEST match, so it stops at the first ": " — the label,
    # whether that is "available" or "defaults design_review". The trailing sed trims each
    # entry and has to stay a sed: it works on the stream, not on one string.
    tr ',' '\n' <<<"${1#SUMMARY *: }" | sed 's/^ *//; s/ *$//'
}
defaults_not_available() {      # $1 = a probe's stdout; echoes " <preset>/<entry>" per failure
    local out="$1" avail_entries dline dname aname found bad=""
    avail_entries="$(summary_entries "$(grep '^SUMMARY available:' <<<"$out")")"
    for dline in design_review code_review; do
        while IFS= read -r dname; do
            [ -n "$dname" ] || continue
            # "—" and "— (preset empty)" are placeholders for "no preset", not entries.
            case "$dname" in —*) continue ;; esac
            found=0
            while IFS= read -r aname; do
                [ -n "$aname" ] || continue
                if [ "$dname" = "$aname" ]; then found=1; break; fi
                if [ "$dname" = claude ]; then
                    case "$aname" in claude:*) found=1; break ;; esac
                fi
            done <<<"$avail_entries"
            [ "$found" = 1 ] || bad="$bad $dline/$dname"
        done <<<"$(summary_entries "$(grep "^SUMMARY defaults $dline:" <<<"$out")")"
    done
    printf '%s' "$bad"
}

# The helper's own contract, on synthetic input. The substring false-accept it fixes cannot be
# reached through any config today — all models of one provider share a status, so a shorter id
# is available exactly when its longer sibling is — which is why it takes three lines of input
# rather than a fixture to state the rule.
assert_eq "a defaults entry that is only a SUBSTRING of an available one is not a match" \
    " design_review/zai/glm" "$(defaults_not_available \
    "$(printf 'SUMMARY available: zai/glm-air\nSUMMARY defaults design_review: zai/glm\nSUMMARY defaults code_review: —\n')")"
assert_eq "…while a bare claude IS satisfied by claude:<model>" "" "$(defaults_not_available \
    "$(printf 'SUMMARY available: claude:opus, claude:fable\nSUMMARY defaults design_review: claude\nSUMMARY defaults code_review: —\n')")"
assert_eq "…and that exception does not run the other way" " design_review/claude:opus" \
    "$(defaults_not_available \
    "$(printf 'SUMMARY available: claude\nSUMMARY defaults design_review: claude:opus\nSUMMARY defaults code_review: —\n')")"

run_probe valid-full.yaml PREFLIGHT_CURL_BIN="$SHIM/curl" PATH="$SHIM:$PATH" SHIM_HTTP_CODE=200
AVAIL="$(grep '^SUMMARY available:' <<<"$OUT")"
UNAVAIL="$(grep '^SUMMARY unavailable:' <<<"$OUT")"
assert_match "claude available when config is usable" "claude"      "$AVAIL"
assert_match "reachable provider expands to model ids" "zai/glm"    "$AVAIL"
assert_match "…for every model of that provider"  "ollama/kimi"     "$AVAIL"
assert_match "…including the second one"          "ollama/deepseek" "$AVAIL"
assert_match "unconfigured codex listed as unavailable" "codex (MISSING)" "$UNAVAIL"
assert_match "defaults lines present"             "SUMMARY defaults design_review:" "$OUT"
# valid-full.yaml has no defaults: section at all. A bare "—" would be ambiguous with the
# no-config run further down, where the preset was never read — this fixture DID read it and
# found it empty, and a session deciding whether `default` mode is usable must tell the two
# apart. Both presets are asserted: reading one and printing it twice would pass on one line.
assert_match "empty preset says which kind of empty" "SUMMARY defaults design_review: — (preset empty)" "$OUT"
assert_match "…and code_review is read separately"  "SUMMARY defaults code_review: — (preset empty)"   "$OUT"
# The one-line fix belongs to a broken environment only. Printed on every run it becomes noise
# the reading session learns to skip, and here it would contradict the healthy rows above it.
assert_no_match "no fix hint when the config is usable" "hint:" "$OUT"
# Everything WAS probed here, so the skip-network note must be absent. Without this assertion
# the note below could be unconditional and no scenario would notice.
assert_no_match "…and no skip-network note on a probed run" "SUMMARY note:" "$OUT"

# The catalog expands into the UI's own spelling — decision 5's "nothing has to be mapped"
# holds for Claude reviewers too (valid-claude-models.yaml carries opus + fable).
run_probe valid-claude-models.yaml
assert_match "catalog expands as claude:<model>"  "claude:opus, claude:fable" "$(grep '^SUMMARY available:' <<<"$OUT")"

run_probe valid-full.yaml PREFLIGHT_CURL_BIN="$SHIM/curl" PATH="$SHIM:$PATH" SHIM_HTTP_CODE=000
AVAIL="$(grep '^SUMMARY available:' <<<"$OUT")"
UNAVAIL="$(grep '^SUMMARY unavailable:' <<<"$OUT")"
assert_match "claude survives a dead network"     "claude"          "$AVAIL"
assert_no_match "dead provider not offered"       "zai/glm"         "$AVAIL"
assert_match "…and is named with its verdict"     "zai/glm (NO-NETWORK)" "$UNAVAIL"

run_probe none
assert_match "no config -> nothing selectable"       "SUMMARY available: —" "$OUT"
assert_match "…claude named with the reason"         "claude (config.yaml required" "$OUT"
assert_match "…and the one-line fix is hinted"       "hint: mkdir -p" "$OUT"
assert_match "…which copies the example into place"   "&& cp config.example.yaml" "$OUT"
# The presets cannot be read without a config, and saying so is not the same as saying the
# preset is empty — the loader was never asked.
assert_match "…and the preset lines degrade, not crash" "SUMMARY defaults design_review: —" "$OUT"
assert_match "…both of them"                            "SUMMARY defaults code_review: —"   "$OUT"

# `CONFIG_STATUS != OK` is THREE states, and the hint is a literally executable command. Only
# the MISSING one above may say `cp config.example.yaml …`: in the other two a real config.yaml
# exists, that command OVERWRITES it — provider tokens and all — and config.yaml is user-owned
# (mesh-review/commands/mesh-review.md Step 1: agents never edit it). The generated prompts tell a session
# to print this table verbatim, so the wrong hint here is a destructive instruction with the
# probe's authority behind it.
run_probe invalid-no-providers.yaml
assert_eq   "rejected config -> nothing selectable" "SUMMARY available: —" "$(grep '^SUMMARY available:' <<<"$OUT")"
assert_match "…claude named with the rejection, not with a missing file" "claude (config.yaml is rejected" "$OUT"
assert_match "…and the hint says to EDIT the file"   "hint: edit"        "$OUT"
assert_match "…because it is the operator's, not ours" "do NOT overwrite" "$OUT"
assert_no_match "…never offering to overwrite a real config" "cp config.example.yaml" "$OUT"

# UNKNOWN is the worst of the three to get wrong: the loader never ran, so the config may well
# be perfect and the only thing missing is yq. Naming what to install matters here too: both
# flavors are accepted, so the advice has to name both.
run_probe valid-claude-models.yaml PREFLIGHT_YQ_BIN="$WORK/no-such-yq"
assert_eq   "unevaluated config -> nothing selectable either" "SUMMARY available: —" "$(grep '^SUMMARY available:' <<<"$OUT")"
assert_match "…claude says exactly that, and not that a file is missing" "claude (config state could not be evaluated" "$OUT"
assert_match "…the hint names the tool the rows above reported" "install a yq that emits JSON" "$OUT"
assert_match "…and says the config itself was never read"       "was never read"  "$OUT"
assert_no_match "…never offering to overwrite an unread config" "cp config.example.yaml" "$OUT"

# UNKNOWN has TWO causes and one hint line, so the hint has to know which one it is advising
# about. It used to be a `*)` arm prescribing yq/jq for both — an operator whose TMPDIR is
# unwritable sent to install a toolchain that is already installed, against a config row that
# says nothing about it. The two assertions are a pair: the second is what makes the first
# more than "the arm printed something".
run_probe valid-claude-models.yaml TMPDIR="$WORK/no-such-tmpdir"
assert_eq   "unevaluated config (no temp file) -> nothing selectable" "SUMMARY available: —" \
    "$(grep '^SUMMARY available:' <<<"$OUT")"
assert_match "…claude blocked with the same could-not-evaluate reason" "claude (config state could not be evaluated" "$OUT"
assert_match "…and the hint points at TMPDIR"                   "hint: make TMPDIR" "$OUT"
assert_no_match "…not at a toolchain that is already installed" "install the loader toolchain" "$OUT"
assert_no_match "…and never at yq"                              "install a yq that emits JSON" "$OUT"
assert_match "…while still saying the config was never read"    "was never read"  "$OUT"
assert_no_match "…and never offering to overwrite it"           "cp config.example.yaml" "$OUT"

# MISSING has a second face since the rename. Up to 0.15.0 the config lived in Claude Code's
# plugin-data dir, so on the first run after the update the tokens are still there while
# ~/.config/mesh/config.yaml does not exist yet, and `cp config.example.yaml` would start a
# blank config beside the one that holds them. The loader names the old copy and prints the
# command that moves it (config-loader.sh, load_or_die); the hint has to be that command.
# MESH_CONFIG is blanked so the loader resolves its default path under the scratch HOME, as a
# real first run does. The old config is a dummy: two lines, one of them a marker.
OLDH="$(mktemp -d "$WORK/home-old-XXXXXX")"
OLDCFG="$OLDH/.claude/plugins/data/claude-mesh-zinin/config.yaml"
mkdir -p "${OLDCFG%/*}"
printf 'providers: {}\nmodels: []   # dummy-old-config-body\n' > "$OLDCFG"
run_probe none HOME="$OLDH" MESH_CONFIG=
assert_eq    "old claude-mesh config, no new one -> still MISSING" MISSING "$(field config "$OUT")"
assert_match "…and the hint moves the old config into place" \
    "cp \"$OLDCFG\" \"$OLDH/.config/mesh/config.yaml\"" "$OUT"
assert_no_match "…never a blank example in its stead" "cp config.example.yaml" "$OUT"
assert_eq    "…the loader's own command, verbatim, after a lead naming the old copy" \
    "hint: the claude-mesh config is still at $OLDCFG — move it: mkdir -p \"$OLDH/.config/mesh\" && cp \"$OLDCFG\" \"$OLDH/.config/mesh/config.yaml\" && chmod 600 \"$OLDH/.config/mesh/config.yaml\"" \
    "$(grep '^hint:' <<<"$OUT")"
# Paths only: nothing on either stream may come from inside the old file.
assert_no_match "…and none of the old config's contents, on either stream" \
    "dummy-old-config-body" "$OUT$ERR"

# The other half of the same branch: an empty HOME has nothing to move, and the advice stays
# the example, copied from the plugin root to the path the loader resolves, with mode 600.
NEWH="$(mktemp -d "$WORK/home-new-XXXXXX")"
run_probe none HOME="$NEWH" MESH_CONFIG=
assert_eq    "no old config -> the example hint, unchanged" \
    "hint: mkdir -p \"$NEWH/.config/mesh\" && (cd \"$(cd "$TESTS_DIR/../../.." && pwd)\" && cp config.example.yaml \"$NEWH/.config/mesh/config.yaml\") && chmod 600 \"$NEWH/.config/mesh/config.yaml\" — the review skills need it even for the built-in claude reviewer" \
    "$(grep '^hint:' <<<"$OUT")"

# The note qualifies "(UNKNOWN)" markers. With no usable config every entry reads (SKIPPED) and
# there is no network verdict to qualify, so the note would point at a marker that is not on the
# page — the flag alone is not the condition.
run_probe none PREFLIGHT_SKIP_NETWORK=1
assert_no_match "no (UNKNOWN) on the page -> no note about one" "SUMMARY note:" "$OUT"
assert_match    "…and the entries really are SKIPPED"           "codex (SKIPPED)" "$OUT"

# A populated defaults: preset — the only way to exercise the expansion end to end. The two
# presets differ on purpose: reading design_review twice, or reading the wrong one, cannot pass
# both assertions. This is also the first exercise of `get-defaults code_review`, which the plan
# left flagged for verification here.
run_probe valid-defaults-preset.yaml PREFLIGHT_CURL_BIN="$SHIM/curl" PATH="$SHIM:$PATH" SHIM_HTTP_CODE=200
assert_match "design_review preset in UI spelling" \
    "SUMMARY defaults design_review: codex, claude:opus, zai/glm" "$OUT"
assert_match "code_review is a different preset, read separately" \
    "SUMMARY defaults code_review: claude:fable, zai/glm" "$OUT"
assert_eq "every default name is spelled as the available line spells it" "" \
    "$(defaults_not_available "$OUT")"

# The no-catalog fallback of the same expansion: `builtin: [claude]` with no claude.models
# means ONE reviewer literally named `claude` (mesh-design-review Step 5.1), and that is the
# spelling the available line uses too. Silently dropping claude here would tell a session that
# `default` mode runs without the reviewer it actually runs first.
run_probe valid-defaults-no-catalog.yaml PREFLIGHT_CURL_BIN="$SHIM/curl" PATH="$SHIM:$PATH" SHIM_HTTP_CODE=200
assert_match "no catalog -> the preset says plain claude" \
    "SUMMARY defaults design_review: claude, zai/glm" "$OUT"
assert_match "…and a preset of claude alone is not empty" \
    "SUMMARY defaults code_review: claude" "$OUT"
assert_match "…which is exactly how the available line spells it" \
    "SUMMARY available: claude, zai/glm" "$OUT"
assert_eq '…so default mode is selectable here too' "" "$(defaults_not_available "$OUT")"

# The crossed shape: a catalog IS present AND the preset omits claude_models. The two lines then
# legitimately disagree — the UI offers claude:opus/claude:fable, `default` mode runs one
# reviewer named `claude` — and this is the only fixture where the membership check has to know
# that those are the same reviewer rather than a spelling drift.
run_probe valid-defaults-claude-bare.yaml PREFLIGHT_CURL_BIN="$SHIM/curl" PATH="$SHIM:$PATH" SHIM_HTTP_CODE=200
assert_match "catalog present, preset bare -> the UI spelling on available" \
    "SUMMARY available: claude:opus, claude:fable, zai/glm" "$OUT"
assert_match "…and the orchestrator's spelling on the preset line" \
    "SUMMARY defaults design_review: claude, zai/glm" "$OUT"
assert_eq "…and the two are reconciled, not reported as a mismatch" "" "$(defaults_not_available "$OUT")"

# The grok half of the same expansion, and the reason it has to exist: SUMMARY available spells
# this reviewer grok:<model>, so a defaults line printing a bare `grok` would name a reviewer the
# available line never offers, and the membership check would answer the wrong question. The
# preset's grok_models is a strict SUBSET of the catalog, and differs per preset, on purpose.
run_probe valid-grok-defaults.yaml PREFLIGHT_CURL_BIN="$SHIM/curl" \
          PATH="$WORK/cli-grok:$SHIM:$PATH" SHIM_HTTP_CODE=200
assert_match "grok on a defaults line is spelled grok:<model>" \
    "SUMMARY defaults design_review: grok:grok-4.6, zai/glm" "$OUT"
assert_match "…from the preset's own list, not the whole catalog" \
    "SUMMARY defaults code_review: grok:grok-4.5" "$OUT"
assert_eq "…so default mode stays a plain membership check" "" "$(defaults_not_available "$OUT")"

# native is the same membership trap as grok: SUMMARY available spells native:<slug>, so a
# defaults line that printed a bare `native` (the leftover-builtin passthrough) would make
# `default` look unsafe on a working Grok host. native_models is a strict subset, different
# per preset, on purpose. No grok: section — grok:<slug> must not appear as the native name.
run_probe valid-native-defaults.yaml PREFLIGHT_CURL_BIN="$SHIM/curl" \
          PATH="$WORK/cli-grok:$SHIM:$PATH" SHIM_HTTP_CODE=200
assert_match "native on a defaults line is spelled native:<slug>" \
    "SUMMARY defaults design_review: native:grok-4.6, zai/glm" "$OUT"
assert_match "…from the preset's own list, not the whole host listing" \
    "SUMMARY defaults code_review: native:grok-4.5" "$OUT"
assert_match "…and available uses the same native:<slug> spelling" \
    ", native:grok-4.6, " "$(avail_wrap "$OUT")"
assert_no_match "…which is not grok:<slug>" \
    ", grok:grok-4.6, " "$(avail_wrap "$OUT")"
assert_eq "…so default mode stays a plain membership check with native too" "" \
    "$(defaults_not_available "$OUT")"

# The SAME fixture on a Claude-Code-shaped host: no grok CLI, so no listing and no native:*
# in available, while the defaults line still expands native over native_models. That gap is
# real on Grok and a false alarm on Claude Code — where `native` collapses into `claude` and
# native_models is ignored — and the script cannot tell the two hosts apart (host detection is
# `spawn_subagent` presence, invisible from a shell; grok-on-PATH is not a proxy, since a
# Claude Code session can have the CLI installed and answering). So it must SAY so rather than
# guess. Until this case was tested, the fixture only ever ran with a grok shim on PATH.
run_probe valid-native-defaults.yaml PREFLIGHT_CURL_BIN="$SHIM/curl" \
          PATH="$SHIM:$PATH" PREFLIGHT_SKIP_NETWORK=1
assert_match "no grok CLI → native-models does not run"  "native-models"  "$OUT"
assert_no_match "…so no native:<slug> reaches available" ", native:"      "$(avail_wrap "$OUT")"
assert_match "…while the defaults line still names one"  "native:grok-4.6" "$OUT"
assert_match "…and a note explains the gap is host-conditional" \
    "SUMMARY note: a preset names \`native\`" "$OUT"

# The mirror case on a WORKING host: `native` in builtin with an EMPTY native_models is the
# documented session-model fallback, so the defaults line prints a bare `native`. available
# has to carry the bare name too — claude and grok both do — or a healthy Grok host reads as
# "default mode unsafe".
run_probe valid-native-defaults.yaml PREFLIGHT_CURL_BIN="$SHIM/curl" \
          PATH="$WORK/cli-grok:$SHIM:$PATH" SHIM_HTTP_CODE=200
assert_match "a live listing also offers the bare native fallback" \
    ", native, " "$(avail_wrap "$OUT")"
assert_no_match "…and needs no host-conditional note" \
    "SUMMARY note: a preset names" "$OUT"

# A fast re-run probes nothing, so every network verdict is UNKNOWN. UNKNOWN is not a degraded
# OK — treating it as unavailable reports a fully working machine as "claude only", and the
# reading session cannot see the flag it did not set. The summary has to say so itself.
run_probe valid-full.yaml PREFLIGHT_CURL_BIN="$SHIM/curl" PATH="$SHIM:$PATH" PREFLIGHT_SKIP_NETWORK=1
AVAIL="$(grep '^SUMMARY available:' <<<"$OUT")"
UNAVAIL="$(grep '^SUMMARY unavailable:' <<<"$OUT")"
assert_eq   "skip-network still offers claude"      "SUMMARY available: claude" "$AVAIL"
assert_match "…and names the unprobed model UNKNOWN" "zai/glm (UNKNOWN)"        "$UNAVAIL"
assert_match "…with the summary saying nothing was probed" "SUMMARY note: PREFLIGHT_SKIP_NETWORK" "$OUT"

# A rejected `claude:` section is not just the claude-models row: both orchestrators `|| exit 1`
# on that same list-claude-models read in their Step 1 / Step 5.0 fence,
# BEFORE any reviewer is offered. So nothing is selectable — not claude, not a reachable model —
# and offering any of it sends the session into the dead end the config gate exists to prevent.
run_probe invalid-claude-scalar.yaml PREFLIGHT_CURL_BIN="$SHIM/curl" PATH="$SHIM:$PATH" SHIM_HTTP_CODE=200
UNAVAIL="$(grep '^SUMMARY unavailable:' <<<"$OUT")"
assert_eq   "rejected claude: catalog -> nothing selectable" \
    "SUMMARY available: —" "$(grep '^SUMMARY available:' <<<"$OUT")"
assert_match "…claude named with the orchestrator's own reason" "claude (the claude: section is rejected" "$UNAVAIL"
assert_match "…and a REACHABLE model is blocked, not offered"   "zai/glm (blocked)" "$UNAVAIL"
assert_match "…with a fix that points at the row above"         "hint: fix the claude: section" "$OUT"

# SUMMARY must agree with the per-row verdicts — the one assertion that catches a
# PROBED_STATUS desync on any future edit, instead of leaving it to a human eye.
run_probe valid-full.yaml PREFLIGHT_CURL_BIN="$SHIM/curl" PATH="$SHIM:$PATH" SHIM_HTTP_CODE=200
AVAIL="$(grep '^SUMMARY available:' <<<"$OUT")"
UNAVAIL="$(grep '^SUMMARY unavailable:' <<<"$OUT")"
BAD_SUMMARY=""
while read -r PNAME PSTAT _; do
    P="${PNAME#provider:}"
    if [ "$PSTAT" = OK ]; then
        case "$UNAVAIL" in *" $P/"*|*": $P/"*) BAD_SUMMARY="$BAD_SUMMARY $P" ;; esac
    else
        case "$AVAIL" in *" $P/"*|*": $P/"*) BAD_SUMMARY="$BAD_SUMMARY $P" ;; esac
    fi
done <<<"$(grep '^provider:' <<<"$OUT")"
assert_eq "SUMMARY agrees with provider rows" "" "$BAD_SUMMARY"

# Row order is part of the contract — a reader scanning top-down meets the toolchain, then the
# config state, then the reviewers, then the environment, then the summary. This assertion is the
# one place the whole table is checked at once, so it also catches a block appended in the wrong
# place.
run_probe valid-full.yaml PREFLIGHT_CURL_BIN="$SHIM/curl" PATH="$SHIM:$PATH" SHIM_HTTP_CODE=200
ORDER="$(awk 'NF>=2 && $1 !~ /^SUMMARY/ {print $1}' <<<"$OUT" | tr '\n' ' ')"
assert_eq "row order is the documented one" \
  "plugin yq jq config builtin-claude claude-models codex gemini grok native-models claude-cli provider:zai provider:ollama git-remote gh glab bash-timeout " \
  "$ORDER"

# Accumulating, in the spirit of the FINAL GATES below but specific to this task: the two lines
# every generated prompt tells its session to read must exist in EVERY scenario, including the
# ones whose answer is "nothing". Per-scenario assertions only cover the runs someone thought
# about; by here ALL_OUT holds all of them, broken toolchain and missing config included.
assert_eq "every scenario printed exactly one 'SUMMARY available:'" \
    "$PROBE_N" "$(grep -c '^SUMMARY available: ' <<<"$ALL_OUT")"
assert_eq "…and exactly one 'SUMMARY unavailable:'" \
    "$PROBE_N" "$(grep -c '^SUMMARY unavailable: ' <<<"$ALL_OUT")"

echo "=== Interrupt contract: a signal must not strand the token file ==="
# The one contract with no coverage at all until now: deleting the INT/TERM traps AND emptying
# cleanup() left this suite green, though those traps exist for nothing but unlinking a mode-600
# file holding a provider token.
#
# Deliberately NOT run_probe: this scenario exits non-zero on purpose, and run_probe feeds every
# rc into BAD_RC, whose gate is "every verdict exits 0". An interrupt is not a verdict, so it
# must stay out of that accumulator — and out of ALL_OUT, whose table is cut off mid-run here.
#
# The curl shim stalls inside the provider probe, which is precisely the window where the env
# file is on disk: probe_provider sources it, runs the precheck, and unlinks it only afterwards.
mkdir -p "$WORK/curlstall"
printf '#!/usr/bin/env bash\nsleep 3\nexit 1\n' > "$WORK/curlstall/curl"
chmod +x "$WORK/curlstall/curl"
ICFG="$(mktemp -d "$WORK/int-XXXXXX")"
cp "$TESTS_DIR/fixtures/valid-claude-models.yaml" "$ICFG/config.yaml"
env MESH_CONFIG="$ICFG/config.yaml" XDG_STATE_HOME="$ICFG" TMPDIR="$ICFG" \
    PREFLIGHT_CURL_BIN="$WORK/curlstall/curl" PATH="$WORK/curlstall:$WORK/grokskip:$PATH" \
    bash "$SCRIPT" >/dev/null 2>&1 &
IPID=$!
IW=0
while [ "$IW" -lt 150 ]; do
    find "$ICFG" -name 'mesh-env-*' 2>/dev/null | grep -q . && break
    kill -0 "$IPID" 2>/dev/null || break
    sleep 0.1; IW=$((IW+1))
done
assert_eq   "the token file exists while the probe is mid-flight" \
            1 "$([ "$(find "$ICFG" -name 'mesh-env-*' 2>/dev/null | grep -c .)" -ge 1 ] && echo 1 || echo 0)"
kill -TERM "$IPID" 2>/dev/null
wait "$IPID" 2>/dev/null; IRC=$?
# 143, not 0: "every verdict exits 0" covers completed runs, and an interrupt is not one.
assert_eq   "an interrupted probe exits 143, never 0"  143 "$IRC"
assert_eq   "…and the token file is gone"              0 \
            "$(find "$ICFG" -name 'mesh-env-*' 2>/dev/null | grep -c . | tr -d ' ')"
# The directory is what makes the guarantee reachable at all — the loader creates the file
# inside the command substitution, so a name-only trap has nothing to delete until export
# returns. If a future loader stops honouring TMPDIR, this is the assertion that fails.
assert_eq   "…and so is the private directory that held it" 0 \
            "$(find "$ICFG" -maxdepth 1 -type d -name 'tmp.*' 2>/dev/null | grep -c . | tr -d ' ')"

# ============================================================================
echo "== Bash tool timeout ceiling =="

# The harness caps a FOREGROUND Bash call at the LARGER of BASH_MAX_TIMEOUT_MS and
# BASH_DEFAULT_TIMEOUT_MS and SIGTERMs it at the cap, taking the whole process group with it.
# The exec skills launch their engine in the background, where the cap does not apply, so a low
# ceiling is not a blocker — it is what a wrapper that ignores that instruction runs into, and
# what any long foreground command a session runs by hand (this suite takes ~3 minutes) runs
# into. On a machine whose settings.json carries no env block the user has no way to know the
# number until a review dies at 600s, which is precisely the case the probe exists for.
run_probe valid-claude-models.yaml BASH_MAX_TIMEOUT_MS=3600000
assert_eq   "ceiling at global_sec -> OK"        OK  "$(field bash-timeout "$OUT")"

run_probe valid-claude-models.yaml BASH_MAX_TIMEOUT_MS=600000
assert_eq   "stock 10-minute ceiling -> LOW"     LOW "$(field bash-timeout "$OUT")"
# The detail must carry the number to set, not just the complaint: the fixture has no runtime
# section, so global_sec is the 3600 default and the remedy is 3600000.
assert_match "LOW detail names the value to set" "BASH_MAX_TIMEOUT_MS=3600000" "$OUT"

# Unset is not "no opinion" — it is the harness default of 600000, which sits below the budget.
# Passed as an empty assignment because `env -u` cannot be threaded through run_probe's "$@",
# and because the developer running this suite may well have the variable exported already.
run_probe valid-claude-models.yaml BASH_MAX_TIMEOUT_MS=
assert_eq   "unset -> LOW on the stock default"  LOW "$(field bash-timeout "$OUT")"

# The effective ceiling is the larger of the two, so a raised DEFAULT alone clears it.
run_probe valid-claude-models.yaml BASH_MAX_TIMEOUT_MS=600000 BASH_DEFAULT_TIMEOUT_MS=3600000
assert_eq   "default above max lifts the ceiling" OK "$(field bash-timeout "$OUT")"

# A non-numeric value is what the harness would ignore; the probe must read it as the default
# rather than feeding it to `[ -ge ]`, where the error would be swallowed and the row skipped.
run_probe valid-claude-models.yaml BASH_MAX_TIMEOUT_MS=abc
assert_eq   "garbage value falls back to default" LOW "$(field bash-timeout "$OUT")"

# No config means no global_sec to compare against — the row says so instead of inventing one.
run_probe none
assert_eq   "no config -> ceiling SKIPPED"   SKIPPED "$(field bash-timeout "$OUT")"

# ============================================================================
# FINAL GATES — must stay LAST. Tasks 2-4 append their scenario sections ABOVE
# this banner. Both gates read every scenario's output, not just the last one.
# ============================================================================

# The closed status set is the contract every later task must keep. Read from ALL_OUT, not
# $OUT: over a single scenario this gate only ever sees that author's statuses, and the
# unusual ones (UNKNOWN, SKIPPED, INVALID) live in scenarios nobody would think to point it at.
#
# The awk filter skips the two kinds of legitimate NON-ROW prose the probe prints: Task 4's
# `SUMMARY …` lines and its `hint: …` line. The hint keys on $1 ALONE and must keep doing so —
# its second word varies with the config state it is advising about (cp / edit / install), so a
# filter written against "cp" would let two of the three variants through and report their third
# word as a status. Extend this filter when a task adds a new non-row line — and do NOT replace
# it with a "every line matches a row shape" regexp: row names legitimately contain a colon
# (provider:zai, Task 2),
# so a shape check is the same forward-compatibility trap in a new costume.
ROWS="$(awk 'NF>=2 && $1 !~ /^SUMMARY/ && $1 != "hint:" {print $2}' <<<"$ALL_OUT")"
BAD="$(sort -u <<<"$ROWS" | grep -Ev '^(OK|MISSING|NO-NETWORK|AUTH-FAILED|INVALID|LOW|SKIPPED|SKIP|UNKNOWN)$' || true)"
assert_eq   "status column stays in the closed set (every scenario)" "" "$BAD"
# Both gates above and below pass on empty input, so they must prove they looked at something.
# Today: 7 scenarios x 4-5 rows = 29. The floor only gets safer as Tasks 2-4 add scenarios.
assert_eq   "…and the gate actually examined rows" \
            1 "$([ "$(grep -c . <<<"$ROWS")" -ge 10 ] && echo 1 || echo 0)"

# "Every verdict exits 0" is THE contract of this probe, and Tasks 2-4 each append a section
# whose last command silently decides the script's exit status. Asserting RC per scenario
# only covers the scenarios someone remembered; this backstop covers all of them.
assert_eq   "every verdict exits 0" "" "$BAD_RC"

# stdout is the table; stderr is progress chatter and NOTHING else. The real regression this
# guards is a dropped `2>&1` on a precheck invocation: token-precheck.sh prints up to 400
# bytes of raw provider response body (:49) and ollama-precheck.sh prints the URL, so the
# probe would start emitting other people's diagnostics — and, for a provider that echoes the
# request, potentially the token itself. A per-scenario "the token is not in $ERR" assertion
# cannot catch that: neither precheck prints the token today, so it can never fail.
#
# The filter is a PREFIX, deliberately: Task 3's cli_row adds `probing codex (https://…)…`
# and `probing gemini (…)…`. Pinning exact text would break there; `^probing ` covers every
# such line and still rejects `token-precheck: OK (HTTP 200) — token appears valid`.
BAD_ERR="$(grep -v '^probing ' <<<"$ALL_ERR" | grep -c . || true)"
assert_eq   "stderr carries only probe chatter, never precheck diagnostics" 0 "$BAD_ERR"
# Same pairing as the closed-set gate above: a gate that passes on empty input must prove it
# had input. 17 probing lines today, across the 10 scenarios that reach a live probe (3 of
# them in the Task 1 section, whose fixtures also carry providers).
assert_eq   "…and that gate saw the chatter it filters" \
            1 "$([ "$(grep -c '^probing ' <<<"$ALL_ERR")" -ge 5 ] && echo 1 || echo 0)"

# The stderr stream has a universal gate above; stdout had only a per-scenario check, inside the
# one run where the shim answers 200. That is the weaker half of the same contract, and the gap
# is reachable: probe_provider puts $url on stdout in all four verdict branches, and
# PROV_DETAIL="export refused: <first line of loader stderr>" copies a raw message there too.
# Mutation-checked: a token planted on stdout in the AUTH-FAILED branch left this suite green
# until these two lines existed.
assert_no_match "no provider token on stdout in ANY scenario" "tkn-zai" "$ALL_OUT"
assert_no_match "…nor on stderr in ANY scenario"              "tkn-zai" "$ALL_ERR"

echo
echo "PASS: $PASS  FAIL: $FAIL"
[ "$FAIL" -eq 0 ]
