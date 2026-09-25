#!/usr/bin/env bash
# Smoke tests for config-loader.sh
set -u
TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
LOADER="$TESTS_DIR/../config-loader.sh"
FIXTURES="$TESTS_DIR/fixtures"

# shellcheck source=lib-yq-doubles.sh
. "$TESTS_DIR/lib-yq-doubles.sh"

FAIL=0
PASS=0

assert_exit() {
    local desc="$1" expected_rc="$2" actual_rc="$3"
    if [ "$expected_rc" = "$actual_rc" ]; then
        PASS=$((PASS+1)); echo "  PASS: $desc"
    else
        FAIL=$((FAIL+1)); echo "  FAIL: $desc (expected rc=$expected_rc, got $actual_rc)"
    fi
}

assert_stderr_contains() {
    local desc="$1" needle="$2" stderr_file="$3"
    if grep -q -- "$needle" "$stderr_file"; then
        PASS=$((PASS+1)); echo "  PASS: $desc"
    else
        FAIL=$((FAIL+1)); echo "  FAIL: $desc (expected stderr to contain: $needle)"
        echo "    stderr was:"; sed 's/^/      /' "$stderr_file"
    fi
}

assert_stderr_lacks() {
    local desc="$1" needle="$2" stderr_file="$3"
    if grep -q -- "$needle" "$stderr_file"; then
        FAIL=$((FAIL+1)); echo "  FAIL: $desc (stderr should NOT contain: $needle)"
        echo "    stderr was:"; sed 's/^/      /' "$stderr_file"
    else
        PASS=$((PASS+1)); echo "  PASS: $desc"
    fi
}

assert_eq_str() {
    # $1 = description, $2 = expected, $3 = actual
    if [ "$2" = "$3" ]; then
        PASS=$((PASS+1)); echo "  PASS: $1"
    else
        FAIL=$((FAIL+1)); echo "  FAIL: $1 — expected '$2', got '$3'"
    fi
}

echo "=== Test 1: missing config file ==="
# iter-2 CONCERN-11: load_or_die exits with rc=2 (distinct from rc=1) when
# config.yaml is missing — so /do-plan (and any future consumer that wants to
# tolerate "no config yet" during fresh setup) can differentiate this case from
# yaml-malformed / validator / env errors. All other commands (validate/export)
# propagate the rc=2 as their own exit code.
ERR=$(mktemp)
NOHOME=$(mktemp -d)   # HOME without a claude-mesh config: the machine's own must not leak in
env -u XDG_CONFIG_HOME -u XDG_STATE_HOME HOME="$NOHOME" MESH_CONFIG=/nonexistent/config.yaml "$LOADER" validate 2>"$ERR"
RC=$?
assert_exit "exits with rc=2 (distinct 'config not found')" "2" "$RC"
assert_stderr_contains "names the missing file" "config.yaml not found at /nonexistent/config.yaml" "$ERR"
assert_stderr_contains "no old config: generic advice" "Copy config.example.yaml" "$ERR"
rm -rf "$ERR" "$NOHOME"

echo "=== Test 1b: an old claude-mesh config gets the exact move command ==="
# First run after the rename: the config still sits in Claude Code's plugin-data dir.
H=$(mktemp -d)
mkdir -p "$H/.claude/plugins/data/claude-mesh-zinin"
cp "$FIXTURES/valid-minimal.yaml" "$H/.claude/plugins/data/claude-mesh-zinin/config.yaml"
ERR=$(mktemp)
env -u MESH_CONFIG -u XDG_CONFIG_HOME -u XDG_STATE_HOME HOME="$H" "$LOADER" validate 2>"$ERR"
RC=$?
assert_exit "still rc=2: nothing is copied for the user" "2" "$RC"
assert_stderr_contains "names the new path" "config.yaml not found at $H/.config/mesh/config.yaml" "$ERR"
assert_stderr_contains "names the old copy" "claude-mesh config is still at $H/.claude/plugins/data/claude-mesh-zinin/config.yaml" "$ERR"
assert_stderr_contains "prints the cp command" "cp \"$H/.claude/plugins/data/claude-mesh-zinin/config.yaml\" \"$H/.config/mesh/config.yaml\"" "$ERR"
assert_eq_str "the new file was not created" "absent" "$([ -e "$H/.config/mesh/config.yaml" ] && echo present || echo absent)"
rm -rf "$H" "$ERR"

echo "=== Test 1c: config-path and data-dir follow XDG and MESH_CONFIG ==="
H=$(mktemp -d)
assert_eq_str "config-path default" "$H/.config/mesh/config.yaml" \
    "$(env -u MESH_CONFIG -u XDG_CONFIG_HOME HOME="$H" "$LOADER" config-path)"
assert_eq_str "config-path under XDG_CONFIG_HOME" "$H/xdg/mesh/config.yaml" \
    "$(env -u MESH_CONFIG HOME="$H" XDG_CONFIG_HOME="$H/xdg" "$LOADER" config-path)"
assert_eq_str "MESH_CONFIG wins over XDG" "$H/other.yaml" \
    "$(HOME="$H" XDG_CONFIG_HOME="$H/xdg" MESH_CONFIG="$H/other.yaml" "$LOADER" config-path)"
assert_eq_str "data-dir default" "$H/.local/state/mesh" \
    "$(env -u XDG_STATE_HOME HOME="$H" "$LOADER" data-dir)"
assert_eq_str "data-dir under XDG_STATE_HOME" "$H/st/mesh" \
    "$(HOME="$H" XDG_STATE_HOME="$H/st" "$LOADER" data-dir)"
assert_eq_str "CLAUDE_PLUGIN_DATA no longer moves anything" "$H/.local/state/mesh" \
    "$(env -u XDG_STATE_HOME HOME="$H" CLAUDE_PLUGIN_DATA="$H/plugin-data" "$LOADER" data-dir)"
rm -rf "$H"

echo "=== Test 2: valid minimal config ==="
TDIR=$(mktemp -d)
cp "$FIXTURES/valid-minimal.yaml" "$TDIR/config.yaml"
ERR=$(mktemp)
MESH_CONFIG="$TDIR/config.yaml" XDG_STATE_HOME="$TDIR" "$LOADER" validate 2>"$ERR"
RC=$?
assert_exit "exits zero on valid config" "0" "$RC"
rm -rf "$TDIR" "$ERR"

echo "=== Test 3: invalid config (no providers) ==="
TDIR=$(mktemp -d)
cp "$FIXTURES/invalid-no-providers.yaml" "$TDIR/config.yaml"
ERR=$(mktemp)
MESH_CONFIG="$TDIR/config.yaml" XDG_STATE_HOME="$TDIR" "$LOADER" validate 2>"$ERR"
RC=$?
assert_exit "exits non-zero on missing providers" "1" "$RC"
assert_stderr_contains "names the issue" "providers" "$ERR"
rm -rf "$TDIR" "$ERR"

echo "=== Test 4: model id without slash ==="
TDIR=$(mktemp -d)
cp "$FIXTURES/invalid-model-no-slash.yaml" "$TDIR/config.yaml"
ERR=$(mktemp)
MESH_CONFIG="$TDIR/config.yaml" XDG_STATE_HOME="$TDIR" "$LOADER" validate 2>"$ERR"
RC=$?
assert_exit "exits non-zero" "1" "$RC"
assert_stderr_contains "explains the slash requirement" 'must be "<provider>/<short>"' "$ERR"
rm -rf "$TDIR" "$ERR"

echo "=== Test 5: model id references missing provider ==="
TDIR=$(mktemp -d)
cp "$FIXTURES/invalid-model-missing-provider.yaml" "$TDIR/config.yaml"
ERR=$(mktemp)
MESH_CONFIG="$TDIR/config.yaml" XDG_STATE_HOME="$TDIR" "$LOADER" validate 2>"$ERR"
RC=$?
assert_exit "exits non-zero" "1" "$RC"
assert_stderr_contains "names the missing provider" "missing provider" "$ERR"
rm -rf "$TDIR" "$ERR"

echo "=== Test 6: model id with empty short ==="
TDIR=$(mktemp -d)
cp "$FIXTURES/invalid-model-empty-short.yaml" "$TDIR/config.yaml"
ERR=$(mktemp)
MESH_CONFIG="$TDIR/config.yaml" XDG_STATE_HOME="$TDIR" "$LOADER" validate 2>"$ERR"
RC=$?
assert_exit "exits non-zero" "1" "$RC"
assert_stderr_contains "explains empty short" "short name after .*/.* is empty" "$ERR"
rm -rf "$TDIR" "$ERR"

echo "=== Test 7: codex.reasoning_level unknown (warn + pass through) ==="
# Forward-compat: unknown levels are NOT fatal — the loader warns on stderr and
# passes the value through (the codex CLI/API is the authority on valid levels).
TDIR=$(mktemp -d)
cp "$FIXTURES/unknown-codex-reasoning.yaml" "$TDIR/config.yaml"
ERR=$(mktemp)
MESH_CONFIG="$TDIR/config.yaml" XDG_STATE_HOME="$TDIR" "$LOADER" validate 2>"$ERR"
RC=$?
assert_exit "exits zero (unknown level warns, not dies)" "0" "$RC"
assert_stderr_contains "warns about the unknown level" "reasoning_level: unknown value" "$ERR"
rm -rf "$TDIR" "$ERR"

echo "=== Test 7b: export ignores codex-section issues (scoped validation) ==="
# cmd_export validation is scoped to providers/models/runtime — the same
# unknown-level fixture must export cleanly with no reasoning_level noise on stderr.
TDIR=$(mktemp -d)
cp "$FIXTURES/unknown-codex-reasoning.yaml" "$TDIR/config.yaml"
OUT=$(mktemp)
ERR=$(mktemp)
MESH_CONFIG="$TDIR/config.yaml" XDG_STATE_HOME="$TDIR" "$LOADER" export zai/glm >"$OUT" 2>"$ERR"
RC=$?
assert_exit "export exits zero despite unknown codex level" "0" "$RC"
if grep -q -- "reasoning_level" "$ERR"; then
    FAIL=$((FAIL+1)); echo "  FAIL: export stderr mentions reasoning_level (codex section is out of export scope)"
    echo "    stderr was:"; sed 's/^/      /' "$ERR"
else
    PASS=$((PASS+1)); echo "  PASS: export stderr silent on reasoning_level"
fi
# cmd_export prints the path to a mode-600 env file; remove it without reading it.
ENV_FILE=$(cat "$OUT" 2>/dev/null)
[ -n "$ENV_FILE" ] && rm -f "$ENV_FILE"
rm -rf "$TDIR" "$OUT" "$ERR"

echo "=== Test 7c: get-codex unaffected by broken gemini section (scoped validation) ==="
# get-codex validates only the codex: section — a gemini: section without model
# must not block config-driven codex resolution (Codex PR-review finding).
# validate stays the full-config lint and still rejects the same fixture.
TDIR=$(mktemp -d)
cp "$FIXTURES/broken-gemini-valid-codex.yaml" "$TDIR/config.yaml"
ERR=$(mktemp)
VAL=$(MESH_CONFIG="$TDIR/config.yaml" XDG_STATE_HOME="$TDIR" "$LOADER" get-codex 2>"$ERR")
RC=$?
assert_exit "get-codex exits zero despite broken gemini section" "0" "$RC"
if [ "$VAL" = "gpt-5.5|xhigh" ]; then
    PASS=$((PASS+1)); echo "  PASS: get-codex prints model|level"
else
    FAIL=$((FAIL+1)); echo "  FAIL: get-codex printed '$VAL' (expected 'gpt-5.5|xhigh')"
fi
if grep -q -- "gemini" "$ERR"; then
    FAIL=$((FAIL+1)); echo "  FAIL: get-codex stderr mentions gemini (out of scope)"
    echo "    stderr was:"; sed 's/^/      /' "$ERR"
else
    PASS=$((PASS+1)); echo "  PASS: get-codex stderr silent on gemini"
fi
MESH_CONFIG="$TDIR/config.yaml" XDG_STATE_HOME="$TDIR" "$LOADER" validate 2>/dev/null
RC=$?
assert_exit "validate (full lint) still rejects the broken gemini section" "1" "$RC"
rm -rf "$TDIR" "$ERR"

echo "=== Test 7d: get-gemini unaffected by broken codex section (scoped validation) ==="
TDIR=$(mktemp -d)
cp "$FIXTURES/broken-codex-valid-gemini.yaml" "$TDIR/config.yaml"
ERR=$(mktemp)
VAL=$(MESH_CONFIG="$TDIR/config.yaml" XDG_STATE_HOME="$TDIR" "$LOADER" get-gemini 2>"$ERR")
RC=$?
assert_exit "get-gemini exits zero despite broken codex section" "0" "$RC"
if [ "$VAL" = "gemini-3.1-pro" ]; then
    PASS=$((PASS+1)); echo "  PASS: get-gemini prints model"
else
    FAIL=$((FAIL+1)); echo "  FAIL: get-gemini printed '$VAL' (expected 'gemini-3.1-pro')"
fi
if grep -q -- "codex" "$ERR"; then
    FAIL=$((FAIL+1)); echo "  FAIL: get-gemini stderr mentions codex (out of scope)"
    echo "    stderr was:"; sed 's/^/      /' "$ERR"
else
    PASS=$((PASS+1)); echo "  PASS: get-gemini stderr silent on codex"
fi
MESH_CONFIG="$TDIR/config.yaml" XDG_STATE_HOME="$TDIR" "$LOADER" validate 2>/dev/null
RC=$?
assert_exit "validate (full lint) still rejects the broken codex section" "1" "$RC"
rm -rf "$TDIR" "$ERR"

echo "=== Test 7e: all known reasoning levels pass silently ==="
# Mutation guard (external review, fix wave 3): removing a level from the known
# set must turn the suite red — previously no test exercised any known level.
for LVL in none minimal low medium high xhigh ultra; do
    TDIR=$(mktemp -d)
    sed "s/reasoning_level: extreme.*/reasoning_level: $LVL/" \
        "$FIXTURES/unknown-codex-reasoning.yaml" > "$TDIR/config.yaml"
    ERR=$(mktemp)
    MESH_CONFIG="$TDIR/config.yaml" XDG_STATE_HOME="$TDIR" "$LOADER" validate 2>"$ERR"
    RC=$?
    assert_exit "validate exits zero on level '$LVL'" "0" "$RC"
    # Scoped assert (fix wave 5): an unrelated future WARN must not break this test —
    # the mutation guard only needs "no reasoning_level noise" (removing a level from
    # the known set emits 'codex.reasoning_level: unknown value …', still caught).
    if grep -q -- "reasoning_level" "$ERR"; then
        FAIL=$((FAIL+1)); echo "  FAIL: stderr mentions reasoning_level on known level '$LVL'"
        echo "    stderr was:"; sed 's/^/      /' "$ERR"
    else
        PASS=$((PASS+1)); echo "  PASS: stderr silent on known level '$LVL'"
    fi
    # Consumer-path round-trip (fix wave 5): executors read get-codex, not validate —
    # a known level must round-trip verbatim and keep the `<model>|<level>` shape
    # (exactly one pipe; the resolution snippets split on the LAST '|').
    VAL=$(MESH_CONFIG="$TDIR/config.yaml" XDG_STATE_HOME="$TDIR" "$LOADER" get-codex 2>/dev/null)
    if [ "$VAL" = "gpt-5.5|$LVL" ]; then
        PASS=$((PASS+1)); echo "  PASS: get-codex round-trips level '$LVL'"
    else
        FAIL=$((FAIL+1)); echo "  FAIL: get-codex printed '$VAL' (expected 'gpt-5.5|$LVL')"
    fi
    rm -rf "$TDIR" "$ERR"
done

echo "=== Test 7f: get-codex passes an unknown level through (the consumer path) ==="
# The executor skills consume get-codex, not validate — lock the passthrough
# contract on the path they actually call.
TDIR=$(mktemp -d)
cp "$FIXTURES/unknown-codex-reasoning.yaml" "$TDIR/config.yaml"
ERR=$(mktemp)
VAL=$(MESH_CONFIG="$TDIR/config.yaml" XDG_STATE_HOME="$TDIR" "$LOADER" get-codex 2>"$ERR")
RC=$?
assert_exit "get-codex exits zero on unknown level" "0" "$RC"
if [ "$VAL" = "gpt-5.5|extreme" ]; then
    PASS=$((PASS+1)); echo "  PASS: get-codex prints model|unknown-level unchanged"
else
    FAIL=$((FAIL+1)); echo "  FAIL: get-codex printed '$VAL' (expected 'gpt-5.5|extreme')"
fi
assert_stderr_contains "warns about the unknown level" "reasoning_level: unknown value" "$ERR"
rm -rf "$TDIR" "$ERR"

echo "=== Test 7g: export unaffected by die-class codex section (scoped validation) ==="
# 7b covers the warn-noise case; this locks the die-class case — a codex: section
# without model must not block ext-claude exports either.
TDIR=$(mktemp -d)
cp "$FIXTURES/broken-codex-valid-gemini.yaml" "$TDIR/config.yaml"
OUT=$(mktemp)
ERR=$(mktemp)
MESH_CONFIG="$TDIR/config.yaml" XDG_STATE_HOME="$TDIR" "$LOADER" export zai/glm >"$OUT" 2>"$ERR"
RC=$?
assert_exit "export exits zero despite die-class codex section" "0" "$RC"
if grep -q -- "codex" "$ERR"; then
    FAIL=$((FAIL+1)); echo "  FAIL: export stderr mentions codex (out of export scope)"
    echo "    stderr was:"; sed 's/^/      /' "$ERR"
else
    PASS=$((PASS+1)); echo "  PASS: export stderr silent on codex"
fi
# cmd_export prints the path to a mode-600 env file; remove it without reading it.
ENV_FILE=$(cat "$OUT" 2>/dev/null)
[ -n "$ENV_FILE" ] && rm -f "$ENV_FILE"
rm -rf "$TDIR" "$OUT" "$ERR"

echo "=== Test 7h: get-codex dies on codex section without model ==="
# The executor STOP contract relies on this rc=1 (resolution snippets surface it).
TDIR=$(mktemp -d)
cp "$FIXTURES/broken-codex-valid-gemini.yaml" "$TDIR/config.yaml"
ERR=$(mktemp)
MESH_CONFIG="$TDIR/config.yaml" XDG_STATE_HOME="$TDIR" "$LOADER" get-codex >/dev/null 2>"$ERR"
RC=$?
assert_exit "get-codex exits non-zero" "1" "$RC"
assert_stderr_contains "names the missing model" "codex.model: required" "$ERR"
rm -rf "$TDIR" "$ERR"

echo "=== Test 7i: non-string reasoning_level dies with a clear message ==="
# Previously an unquoted numeric level passed validate (warn) and then crashed
# get-codex with a raw jq type error (rc=5) — worse than 0.3.0's clean die.
TDIR=$(mktemp -d)
sed "s/reasoning_level: extreme.*/reasoning_level: 3/" \
    "$FIXTURES/unknown-codex-reasoning.yaml" > "$TDIR/config.yaml"
ERR=$(mktemp)
MESH_CONFIG="$TDIR/config.yaml" XDG_STATE_HOME="$TDIR" "$LOADER" validate 2>"$ERR"
RC=$?
assert_exit "validate exits non-zero on numeric level" "1" "$RC"
assert_stderr_contains "explains the type requirement" "must be a string" "$ERR"
MESH_CONFIG="$TDIR/config.yaml" XDG_STATE_HOME="$TDIR" "$LOADER" get-codex >/dev/null 2>/dev/null
RC=$?
assert_exit "get-codex dies cleanly too (no raw jq rc=5)" "1" "$RC"
rm -rf "$TDIR" "$ERR"

echo "=== Test 7j: reasoning_level with unsafe characters dies ==="
# '|' would corrupt the get-codex model|level protocol; quotes/spaces would break
# shell substitution in the executor skills.
TDIR=$(mktemp -d)
sed 's/reasoning_level: extreme.*/reasoning_level: "a|b"/' \
    "$FIXTURES/unknown-codex-reasoning.yaml" > "$TDIR/config.yaml"
ERR=$(mktemp)
MESH_CONFIG="$TDIR/config.yaml" XDG_STATE_HOME="$TDIR" "$LOADER" validate 2>"$ERR"
RC=$?
assert_exit "validate exits non-zero on 'a|b'" "1" "$RC"
assert_stderr_contains "names reasoning_level charset" "codex.reasoning_level: must start with" "$ERR"
rm -rf "$TDIR" "$ERR"

echo "=== Test 7k: codex.model with unsafe characters dies ==="
TDIR=$(mktemp -d)
sed 's/model: gpt-5.5/model: "gpt 5.5"/' \
    "$FIXTURES/unknown-codex-reasoning.yaml" > "$TDIR/config.yaml"
ERR=$(mktemp)
MESH_CONFIG="$TDIR/config.yaml" XDG_STATE_HOME="$TDIR" "$LOADER" validate 2>"$ERR"
RC=$?
assert_exit "validate exits non-zero on 'gpt 5.5'" "1" "$RC"
assert_stderr_contains "names codex.model charset" "codex.model: must start with" "$ERR"
rm -rf "$TDIR" "$ERR"

echo "=== Test 8: defaults references unknown model ==="
TDIR=$(mktemp -d)
cp "$FIXTURES/invalid-defaults-missing-model.yaml" "$TDIR/config.yaml"
ERR=$(mktemp)
MESH_CONFIG="$TDIR/config.yaml" XDG_STATE_HOME="$TDIR" "$LOADER" validate 2>"$ERR"
RC=$?
assert_exit "exits non-zero" "1" "$RC"
assert_stderr_contains "names unknown model" "unknown model" "$ERR"
rm -rf "$TDIR" "$ERR"

echo "=== Test 9: defaults.builtin lists gemini without gemini section ==="
TDIR=$(mktemp -d)
cp "$FIXTURES/invalid-defaults-builtin-gemini-no-section.yaml" "$TDIR/config.yaml"
ERR=$(mktemp)
MESH_CONFIG="$TDIR/config.yaml" XDG_STATE_HOME="$TDIR" "$LOADER" validate 2>"$ERR"
RC=$?
assert_exit "exits non-zero" "1" "$RC"
assert_stderr_contains "explains the missing section" "but no gemini: section" "$ERR"
rm -rf "$TDIR" "$ERR"

echo "=== Test 10: runtime.do_plan_default_stop_tokens is ignored, with a warning ==="
# do-plan moved to session-relay. A config copied over from claude-mesh keeps the key, and
# must still validate — `validate` names it so it gets deleted.
TDIR=$(mktemp -d)
cp "$FIXTURES/invalid-runtime-do-plan-tokens.yaml" "$TDIR/config.yaml"
ERR=$(mktemp)
MESH_CONFIG="$TDIR/config.yaml" XDG_STATE_HOME="$TDIR" "$LOADER" validate 2>"$ERR"
RC=$?
assert_exit "a below-floor value no longer fails validate" "0" "$RC"
assert_stderr_contains "names the ignored key" "do_plan_default_stop_tokens is ignored" "$ERR"
assert_stderr_contains "points at session-relay" "session-relay" "$ERR"
rm -rf "$TDIR" "$ERR"

# iter-2 CONCERN-11: load_or_die exits 2 (not 1) when config.yaml is missing.
echo "=== Test 10b: get-flag returns rc=2 when config.yaml missing ==="
ERR=$(mktemp)
NOHOME=$(mktemp -d)
env -u XDG_CONFIG_HOME HOME="$NOHOME" MESH_CONFIG=/nonexistent/config.yaml "$LOADER" get-flag has_codex 2>"$ERR"
RC=$?
assert_exit "get-flag exits rc=2 on missing config" "2" "$RC"
assert_stderr_contains "names missing config.yaml" "config.yaml not found" "$ERR"
rm -rf "$ERR" "$NOHOME"

echo "=== Test 10c: get-flag do_plan_default_stop_tokens is gone ==="
TDIR=$(mktemp -d)
cp "$FIXTURES/valid-minimal.yaml" "$TDIR/config.yaml"
ERR=$(mktemp)
MESH_CONFIG="$TDIR/config.yaml" XDG_STATE_HOME="$TDIR" "$LOADER" get-flag do_plan_default_stop_tokens 2>"$ERR"
RC=$?
assert_exit "the removed feature is unknown (rc=1)" "1" "$RC"
assert_stderr_contains "says unknown feature" "unknown feature" "$ERR"
GOT=$(MESH_CONFIG="$TDIR/config.yaml" XDG_STATE_HOME="$TDIR" "$LOADER" get-runtime | jq -r 'has("do_plan_default_stop_tokens")')
assert_eq_str "get-runtime no longer carries the key" "false" "$GOT"
rm -rf "$TDIR" "$ERR"

echo "=== Test 11: defaults.models as scalar (not a list) is rejected ==="
TDIR=$(mktemp -d)
cp "$FIXTURES/invalid-defaults-models-scalar.yaml" "$TDIR/config.yaml"
ERR=$(mktemp)
MESH_CONFIG="$TDIR/config.yaml" XDG_STATE_HOME="$TDIR" "$LOADER" validate 2>"$ERR"
RC=$?
assert_exit "exits non-zero on scalar models" "1" "$RC"
assert_stderr_contains "explains it must be a list" "must be a list" "$ERR"
rm -rf "$TDIR" "$ERR"

echo "=== Test 12: export simple model ==="
TDIR=$(mktemp -d)
cp "$FIXTURES/valid-full.yaml" "$TDIR/config.yaml"
OUT=$(mktemp)
MESH_CONFIG="$TDIR/config.yaml" XDG_STATE_HOME="$TDIR" "$LOADER" export zai/glm >"$OUT" 2>/dev/null
RC=$?
assert_exit "export exits zero" "0" "$RC"

ENV_FILE=$(cat "$OUT")
# Secret hygiene (FIX 3): the emitted env file (which holds the token) must be mode 600.
# Stat BEFORE sourcing/removing it.
MODE=$(stat -c %a "$ENV_FILE")
[ "$MODE" = "600" ] && { PASS=$((PASS+1)); echo "  PASS: env file mode 600"; } || { FAIL=$((FAIL+1)); echo "  FAIL: env file mode '$MODE'"; }
# Secret hygiene (FIX 3): the token must NOT appear on stdout (the path is all that goes there).
# $OUT holds the captured export stdout; grep BEFORE $OUT is overwritten/removed.
if grep -q 'tkn-zai' "$OUT"; then FAIL=$((FAIL+1)); echo "  FAIL: token leaked to stdout"; else PASS=$((PASS+1)); echo "  PASS: token absent from stdout"; fi
source "$ENV_FILE"; rm -f "$ENV_FILE"
[ "$ANTHROPIC_BASE_URL" = "https://api.z.ai/api/anthropic" ] \
  && { PASS=$((PASS+1)); echo "  PASS: ANTHROPIC_BASE_URL set"; } \
  || { FAIL=$((FAIL+1)); echo "  FAIL: ANTHROPIC_BASE_URL got '$ANTHROPIC_BASE_URL'"; }
[ "$ANTHROPIC_AUTH_TOKEN" = "tkn-zai" ] \
  && { PASS=$((PASS+1)); echo "  PASS: ANTHROPIC_AUTH_TOKEN set"; } \
  || { FAIL=$((FAIL+1)); echo "  FAIL: ANTHROPIC_AUTH_TOKEN got '$ANTHROPIC_AUTH_TOKEN'"; }
[ "$ANTHROPIC_MODEL" = "glm-5.1" ] \
  && { PASS=$((PASS+1)); echo "  PASS: ANTHROPIC_MODEL set"; } \
  || { FAIL=$((FAIL+1)); echo "  FAIL: ANTHROPIC_MODEL got '$ANTHROPIC_MODEL'"; }
[ "$ANTHROPIC_DEFAULT_HAIKU_MODEL" = "glm-5.1" ] \
  && { PASS=$((PASS+1)); echo "  PASS: haiku defaults to model"; } \
  || { FAIL=$((FAIL+1)); echo "  FAIL: haiku got '$ANTHROPIC_DEFAULT_HAIKU_MODEL'"; }
unset ANTHROPIC_BASE_URL ANTHROPIC_AUTH_TOKEN ANTHROPIC_MODEL ANTHROPIC_DEFAULT_HAIKU_MODEL
rm -rf "$TDIR" "$OUT"

echo "=== Test 13: export model with haiku_model override and context_window ==="
TDIR=$(mktemp -d)
cp "$FIXTURES/valid-full.yaml" "$TDIR/config.yaml"
OUT=$(mktemp)
MESH_CONFIG="$TDIR/config.yaml" XDG_STATE_HOME="$TDIR" "$LOADER" export ollama/deepseek >"$OUT" 2>/dev/null
ENV_FILE=$(cat "$OUT"); source "$ENV_FILE"; rm -f "$ENV_FILE"
[ "$ANTHROPIC_BASE_URL" = "http://127.0.0.1:11434" ] \
  && { PASS=$((PASS+1)); echo "  PASS: ollama base_url"; } \
  || { FAIL=$((FAIL+1)); echo "  FAIL: ollama base_url got '$ANTHROPIC_BASE_URL'"; }
[ "$ANTHROPIC_MODEL" = "deepseek-v4-pro:cloud" ] \
  && { PASS=$((PASS+1)); echo "  PASS: ollama model"; } \
  || { FAIL=$((FAIL+1)); echo "  FAIL: model got '$ANTHROPIC_MODEL'"; }
[ "$ANTHROPIC_DEFAULT_HAIKU_MODEL" = "deepseek-v4-flash:cloud" ] \
  && { PASS=$((PASS+1)); echo "  PASS: haiku override applied"; } \
  || { FAIL=$((FAIL+1)); echo "  FAIL: haiku got '$ANTHROPIC_DEFAULT_HAIKU_MODEL'"; }
[ "$CLAUDE_CODE_AUTO_COMPACT_WINDOW" = "1000000" ] \
  && { PASS=$((PASS+1)); echo "  PASS: context_window exported"; } \
  || { FAIL=$((FAIL+1)); echo "  FAIL: window got '$CLAUDE_CODE_AUTO_COMPACT_WINDOW'"; }
[ "$CLAUDE_MESH_PROVIDER_KIND" = "ollama-daemon" ] \
  && { PASS=$((PASS+1)); echo "  PASS: provider kind exported for precheck routing"; } \
  || { FAIL=$((FAIL+1)); echo "  FAIL: kind got '$CLAUDE_MESH_PROVIDER_KIND'"; }
unset ANTHROPIC_BASE_URL ANTHROPIC_AUTH_TOKEN ANTHROPIC_MODEL ANTHROPIC_DEFAULT_HAIKU_MODEL CLAUDE_CODE_AUTO_COMPACT_WINDOW CLAUDE_MESH_PROVIDER_KIND
rm -rf "$TDIR" "$OUT"

echo "=== Test 14: export nonexistent model ==="
TDIR=$(mktemp -d)
cp "$FIXTURES/valid-full.yaml" "$TDIR/config.yaml"
ERR=$(mktemp)
MESH_CONFIG="$TDIR/config.yaml" XDG_STATE_HOME="$TDIR" "$LOADER" export zai/nope 2>"$ERR"
RC=$?
assert_exit "exits non-zero for unknown model" "1" "$RC"
assert_stderr_contains "names the unknown model" "zai/nope" "$ERR"
rm -rf "$TDIR" "$ERR"

echo "=== Test 15: provider kind invalid value ==="
TDIR=$(mktemp -d)
cp "$FIXTURES/invalid-provider-kind.yaml" "$TDIR/config.yaml"
ERR=$(mktemp)
MESH_CONFIG="$TDIR/config.yaml" XDG_STATE_HOME="$TDIR" "$LOADER" validate 2>"$ERR"
RC=$?
assert_exit "exits non-zero on invalid kind" "1" "$RC"
assert_stderr_contains "names unknown value" "unknown value" "$ERR"
rm -rf "$TDIR" "$ERR"

echo "=== Test 16: provider base_url empty ==="
TDIR=$(mktemp -d)
cp "$FIXTURES/invalid-provider-empty-base-url.yaml" "$TDIR/config.yaml"
ERR=$(mktemp)
MESH_CONFIG="$TDIR/config.yaml" XDG_STATE_HOME="$TDIR" "$LOADER" validate 2>"$ERR"
RC=$?
assert_exit "exits non-zero on empty base_url" "1" "$RC"
assert_stderr_contains "names missing base_url" "base_url: missing" "$ERR"
rm -rf "$TDIR" "$ERR"

echo "=== Test 17: provider base_url not a URL ==="
TDIR=$(mktemp -d)
cp "$FIXTURES/invalid-provider-bad-url.yaml" "$TDIR/config.yaml"
ERR=$(mktemp)
MESH_CONFIG="$TDIR/config.yaml" XDG_STATE_HOME="$TDIR" "$LOADER" validate 2>"$ERR"
RC=$?
assert_exit "exits non-zero on bad URL" "1" "$RC"
assert_stderr_contains "names invalid URL" "invalid URL" "$ERR"
rm -rf "$TDIR" "$ERR"

echo "=== Test 17b: a newline in a label is rejected, like '|' ==="
# Line-based output is the reason: consumers read `list-models` one line at a time, so a
# continuation becomes a phantom entry. In preflight-env.sh it prints as a row whose NAME
# holds spaces, which shifts an arbitrary word into the status column — and that word can be
# spelled AUTH-FAILED, satisfying every closed-set gate with a verdict nothing measured.
TDIR=$(mktemp -d)
printf 'providers:\n  - id: zai\n    label: "Z"\n    base_url: https://api.z.ai/api/anthropic\n    token: "tkn"\nmodels:\n  - id: zai/glm\n    label: "GLM\\nevil AUTH-FAILED injected"\n    model: glm-5.1\n' > "$TDIR/config.yaml"
ERR=$(mktemp)
MESH_CONFIG="$TDIR/config.yaml" XDG_STATE_HOME="$TDIR" "$LOADER" validate 2>"$ERR"
RC=$?
assert_exit "exits non-zero on a newline in a model label" "1" "$RC"
assert_stderr_contains "names the newline" "newline" "$ERR"
rm -rf "$TDIR" "$ERR"

TDIR=$(mktemp -d)
printf 'providers:\n  - id: zai\n    label: "Z\\nevil AUTH-FAILED injected"\n    base_url: https://api.z.ai/api/anthropic\n    token: "tkn"\nmodels:\n  - id: zai/glm\n    label: "GLM"\n    model: glm-5.1\n' > "$TDIR/config.yaml"
ERR=$(mktemp)
MESH_CONFIG="$TDIR/config.yaml" XDG_STATE_HOME="$TDIR" "$LOADER" validate 2>"$ERR"
RC=$?
assert_exit "exits non-zero on a newline in a provider label" "1" "$RC"
assert_stderr_contains "names the newline there too" "newline" "$ERR"
rm -rf "$TDIR" "$ERR"

echo "=== Test 18: provider token REPLACE_ME rejected at export ==="
# By design the REPLACE_ME check lives in cmd_export (NOT validate): the shipped
# config.example.yaml has REPLACE_ME everywhere and must still pass `validate`.
# So this fixture is otherwise-valid (passes validate_all, which runs first inside
# export) and we invoke `export` to trigger the token error.
TDIR=$(mktemp -d)
cp "$FIXTURES/invalid-token-replace-me.yaml" "$TDIR/config.yaml"
ERR=$(mktemp)
MESH_CONFIG="$TDIR/config.yaml" XDG_STATE_HOME="$TDIR" "$LOADER" export zai/glm 2>"$ERR"
RC=$?
assert_exit "export exits non-zero on REPLACE_ME token" "1" "$RC"
assert_stderr_contains "names the still-REPLACE_ME token" 'still "REPLACE_ME"' "$ERR"
rm -rf "$TDIR" "$ERR"

echo "=== Test 19: provider duplicate id ==="
TDIR=$(mktemp -d)
cp "$FIXTURES/invalid-provider-duplicate-id.yaml" "$TDIR/config.yaml"
ERR=$(mktemp)
MESH_CONFIG="$TDIR/config.yaml" XDG_STATE_HOME="$TDIR" "$LOADER" validate 2>"$ERR"
RC=$?
assert_exit "exits non-zero on duplicate provider id" "1" "$RC"
assert_stderr_contains "names duplicate id" "duplicate id" "$ERR"
rm -rf "$TDIR" "$ERR"

echo "=== Test 20: model id with multiple slashes ==="
TDIR=$(mktemp -d)
cp "$FIXTURES/invalid-model-multi-slash.yaml" "$TDIR/config.yaml"
ERR=$(mktemp)
MESH_CONFIG="$TDIR/config.yaml" XDG_STATE_HOME="$TDIR" "$LOADER" validate 2>"$ERR"
RC=$?
assert_exit "exits non-zero on multi-slash id" "1" "$RC"
assert_stderr_contains "explains only one slash allowed" 'only one "/"' "$ERR"
rm -rf "$TDIR" "$ERR"

echo "=== Test 21: model id short part has uppercase ==="
TDIR=$(mktemp -d)
cp "$FIXTURES/invalid-model-uppercase-short.yaml" "$TDIR/config.yaml"
ERR=$(mktemp)
MESH_CONFIG="$TDIR/config.yaml" XDG_STATE_HOME="$TDIR" "$LOADER" validate 2>"$ERR"
RC=$?
assert_exit "exits non-zero on uppercase short" "1" "$RC"
assert_stderr_contains "explains short-name regex" "must match" "$ERR"
rm -rf "$TDIR" "$ERR"

echo "=== Test 22: model id duplicate ==="
TDIR=$(mktemp -d)
cp "$FIXTURES/invalid-model-duplicate.yaml" "$TDIR/config.yaml"
ERR=$(mktemp)
MESH_CONFIG="$TDIR/config.yaml" XDG_STATE_HOME="$TDIR" "$LOADER" validate 2>"$ERR"
RC=$?
assert_exit "exits non-zero on duplicate model id" "1" "$RC"
assert_stderr_contains "names duplicate id" "duplicate id" "$ERR"
rm -rf "$TDIR" "$ERR"

echo "=== Test 23: model.model empty ==="
TDIR=$(mktemp -d)
cp "$FIXTURES/invalid-model-empty-model.yaml" "$TDIR/config.yaml"
ERR=$(mktemp)
MESH_CONFIG="$TDIR/config.yaml" XDG_STATE_HOME="$TDIR" "$LOADER" validate 2>"$ERR"
RC=$?
assert_exit "exits non-zero on empty model field" "1" "$RC"
assert_stderr_contains "names required field" "required field" "$ERR"
rm -rf "$TDIR" "$ERR"

echo "=== Test 24: defaults.builtin lists codex without codex section ==="
TDIR=$(mktemp -d)
cp "$FIXTURES/invalid-defaults-builtin-codex-no-section.yaml" "$TDIR/config.yaml"
ERR=$(mktemp)
MESH_CONFIG="$TDIR/config.yaml" XDG_STATE_HOME="$TDIR" "$LOADER" validate 2>"$ERR"
RC=$?
assert_exit "exits non-zero on codex without section" "1" "$RC"
assert_stderr_contains "explains the missing codex section" "but no codex: section" "$ERR"
rm -rf "$TDIR" "$ERR"

echo "=== Test 25: defaults.builtin unknown value ==="
TDIR=$(mktemp -d)
cp "$FIXTURES/invalid-defaults-builtin-unknown.yaml" "$TDIR/config.yaml"
ERR=$(mktemp)
MESH_CONFIG="$TDIR/config.yaml" XDG_STATE_HOME="$TDIR" "$LOADER" validate 2>"$ERR"
RC=$?
assert_exit "exits non-zero on unknown builtin" "1" "$RC"
assert_stderr_contains "names unknown value" "unknown value" "$ERR"
rm -rf "$TDIR" "$ERR"

echo "=== Test 26: defaults.code_review.run_mode invalid ==="
TDIR=$(mktemp -d)
cp "$FIXTURES/invalid-defaults-runmode.yaml" "$TDIR/config.yaml"
ERR=$(mktemp)
MESH_CONFIG="$TDIR/config.yaml" XDG_STATE_HOME="$TDIR" "$LOADER" validate 2>"$ERR"
RC=$?
assert_exit "exits non-zero on invalid run_mode" "1" "$RC"
assert_stderr_contains "names unknown value" "unknown value" "$ERR"
rm -rf "$TDIR" "$ERR"

echo "=== Test 27: runtime.default_run_mode invalid ==="
TDIR=$(mktemp -d)
cp "$FIXTURES/invalid-runtime-runmode.yaml" "$TDIR/config.yaml"
ERR=$(mktemp)
MESH_CONFIG="$TDIR/config.yaml" XDG_STATE_HOME="$TDIR" "$LOADER" validate 2>"$ERR"
RC=$?
assert_exit "exits non-zero on invalid default_run_mode" "1" "$RC"
assert_stderr_contains "names unknown value" "unknown value" "$ERR"
rm -rf "$TDIR" "$ERR"

echo "=== Test 28: runtime.timeouts.* zero ==="
TDIR=$(mktemp -d)
cp "$FIXTURES/invalid-runtime-timeout-zero.yaml" "$TDIR/config.yaml"
ERR=$(mktemp)
MESH_CONFIG="$TDIR/config.yaml" XDG_STATE_HOME="$TDIR" "$LOADER" validate 2>"$ERR"
RC=$?
assert_exit "exits non-zero on zero timeout" "1" "$RC"
assert_stderr_contains "names positive integer rule" "positive integer" "$ERR"
rm -rf "$TDIR" "$ERR"

echo "=== Test 29: runtime.timeouts.* negative ==="
TDIR=$(mktemp -d)
cp "$FIXTURES/invalid-runtime-timeout-negative.yaml" "$TDIR/config.yaml"
ERR=$(mktemp)
MESH_CONFIG="$TDIR/config.yaml" XDG_STATE_HOME="$TDIR" "$LOADER" validate 2>"$ERR"
RC=$?
assert_exit "exits non-zero on negative timeout" "1" "$RC"
assert_stderr_contains "names positive integer rule" "positive integer" "$ERR"
rm -rf "$TDIR" "$ERR"

echo "=== Test 30: odd model name round-trips verbatim (jq-injection guard, FIX 1) ==="
# Regression for the jq filter-injection fix: the .model field contains `"` and `$`
# (`a" + .providers[0].token + "z`). With the fallback bound as program text this would
# evaluate as a jq expression and splice the provider token into opus/sonnet/haiku/subagent.
# With --arg binding it must round-trip as a literal string. EXPECTED kept in a variable to
# avoid quoting mistakes.
TDIR=$(mktemp -d)
cp "$FIXTURES/valid-odd-model-name.yaml" "$TDIR/config.yaml"
OUT=$(mktemp)
MESH_CONFIG="$TDIR/config.yaml" XDG_STATE_HOME="$TDIR" "$LOADER" export zai/odd >"$OUT" 2>/dev/null
RC=$?
assert_exit "export exits zero on odd model name" "0" "$RC"
ENV_FILE=$(cat "$OUT"); source "$ENV_FILE"; rm -f "$ENV_FILE"
EXPECTED='a" + .providers[0].token + "z'
[ "$ANTHROPIC_MODEL" = "$EXPECTED" ] && { PASS=$((PASS+1)); echo "  PASS: odd model name round-trips (model)"; } || { FAIL=$((FAIL+1)); echo "  FAIL: model got '$ANTHROPIC_MODEL'"; }
[ "$ANTHROPIC_DEFAULT_OPUS_MODEL" = "$EXPECTED" ] && { PASS=$((PASS+1)); echo "  PASS: odd model name round-trips (opus)"; } || { FAIL=$((FAIL+1)); echo "  FAIL: opus got '$ANTHROPIC_DEFAULT_OPUS_MODEL'"; }
[ "$ANTHROPIC_DEFAULT_SONNET_MODEL" = "$EXPECTED" ] && { PASS=$((PASS+1)); echo "  PASS: odd model name round-trips (sonnet)"; } || { FAIL=$((FAIL+1)); echo "  FAIL: sonnet got '$ANTHROPIC_DEFAULT_SONNET_MODEL'"; }
[ "$ANTHROPIC_DEFAULT_HAIKU_MODEL" = "$EXPECTED" ] && { PASS=$((PASS+1)); echo "  PASS: odd model name round-trips (haiku)"; } || { FAIL=$((FAIL+1)); echo "  FAIL: haiku got '$ANTHROPIC_DEFAULT_HAIKU_MODEL'"; }
[ "$CLAUDE_CODE_SUBAGENT_MODEL" = "$EXPECTED" ] && { PASS=$((PASS+1)); echo "  PASS: odd model name round-trips (subagent)"; } || { FAIL=$((FAIL+1)); echo "  FAIL: subagent got '$CLAUDE_CODE_SUBAGENT_MODEL'"; }
unset ANTHROPIC_MODEL ANTHROPIC_DEFAULT_OPUS_MODEL ANTHROPIC_DEFAULT_SONNET_MODEL ANTHROPIC_DEFAULT_HAIKU_MODEL CLAUDE_CODE_SUBAGENT_MODEL
rm -rf "$TDIR" "$OUT"

echo "=== Test 31: full config.example.yaml validates ==="
PLUGIN_ROOT="$(cd "$TESTS_DIR/../../.." && pwd)"
# NB: name this TMPD, not TMPDIR — mktemp consumes a set $TMPDIR as its base dir; clobbering it would break staging.
TMPD=$(mktemp -d)
cp "$PLUGIN_ROOT/config.example.yaml" "$TMPD/config.yaml"
ERR=$(mktemp)
MESH_CONFIG="$TMPD/config.yaml" XDG_STATE_HOME="$TMPD" "$LOADER" validate 2>"$ERR"
RC=$?
assert_exit "config.example.yaml validates" "0" "$RC"
[ "$RC" != "0" ] && { echo "    stderr:"; sed 's/^/      /' "$ERR"; }
rm -rf "$TMPD" "$ERR"

echo "=== Test 32: export every model in config.example.yaml ==="
TMPD=$(mktemp -d)
# iter-3 CRITICAL-4: stage a REPLACE_ME→fake-token copy so cmd_export's
# REPLACE_ME guard (iter-2 CONCERN-10) doesn't trip on the shipped example.
sed 's/REPLACE_ME/test-token-fake/g' "$PLUGIN_ROOT/config.example.yaml" > "$TMPD/config.yaml"
# RAW `yq`, no double: this reaches whatever `yq` the machine actually has, independent of
# lib-yq-doubles.sh and of anything the loader does. Whether that makes the harness
# flavor-DEPENDENT is unsettled and was never measured: `-r` is kislyuk's raw-output flag,
# mikefarah v4 is believed to accept it too as the short form of --unwrapScalar, and
# `.models[].id` is valid in both dialects — but no machine carrying both flavors has run this.
# What is certain is the failure mode if some yq rejects either: $MODEL_IDS comes back empty and
# the loop below runs zero times, so this test would pass while asserting nothing.
MODEL_IDS=$(yq -r '.models[].id' "$TMPD/config.yaml")
for mid in $MODEL_IDS; do
    OUT=$(mktemp)
    ERRF=$(mktemp)
    MESH_CONFIG="$TMPD/config.yaml" XDG_STATE_HOME="$TMPD" "$LOADER" export "$mid" >"$OUT" 2>"$ERRF"
    RC=$?
    ENV_FILE=$(cat "$OUT" 2>/dev/null)
    # cmd_export now prints the path to a mode-600 tmpfile, not the exports themselves.
    if [ "$RC" = "0" ] && [ -n "$ENV_FILE" ] && [ -f "$ENV_FILE" ] && grep -q '^export ANTHROPIC_BASE_URL=' "$ENV_FILE"; then
        PASS=$((PASS+1)); echo "  PASS: export $mid"
    else
        FAIL=$((FAIL+1)); echo "  FAIL: export $mid (rc=$RC, env_file=$ENV_FILE)"
        sed 's/^/      /' "$ERRF"
    fi
    [ -n "$ENV_FILE" ] && rm -f "$ENV_FILE"
    rm -f "$OUT" "$ERRF"
done
rm -rf "$TMPD"

# === Test 33: get-runtime surfaces runtime.max_redispatch from config ===
# (consumed by /mesh-review Step 6.0 guard as the auto-redispatch round cap)
echo "=== Test 33: get-runtime emits max_redispatch from config ==="
TDIR=$(mktemp -d)
printf 'runtime:\n  max_redispatch: 3\n' > "$TDIR/config.yaml"
GOT=$(MESH_CONFIG="$TDIR/config.yaml" XDG_STATE_HOME="$TDIR" "$LOADER" get-runtime | jq -r '.max_redispatch')
if [ "$GOT" = "3" ]; then PASS=$((PASS+1)); echo "  PASS: max_redispatch=3"; else FAIL=$((FAIL+1)); echo "  FAIL: max_redispatch (expected 3, got '$GOT')"; fi
rm -rf "$TDIR"

# === Test 34: get-runtime defaults max_redispatch to 1 when absent ===
echo "=== Test 34: get-runtime defaults max_redispatch to 1 ==="
TDIR=$(mktemp -d)
printf 'runtime:\n  default_run_mode: team\n' > "$TDIR/config.yaml"
GOT=$(MESH_CONFIG="$TDIR/config.yaml" XDG_STATE_HOME="$TDIR" "$LOADER" get-runtime | jq -r '.max_redispatch')
if [ "$GOT" = "1" ]; then PASS=$((PASS+1)); echo "  PASS: default 1"; else FAIL=$((FAIL+1)); echo "  FAIL: default (expected 1, got '$GOT')"; fi
rm -rf "$TDIR"

# === Test 35: validate_runtime rejects non-positive max_redispatch ===
echo "=== Test 35: get-runtime rejects max_redispatch=0 ==="
TDIR=$(mktemp -d)
printf 'runtime:\n  max_redispatch: 0\n' > "$TDIR/config.yaml"
ERR=$(mktemp)
MESH_CONFIG="$TDIR/config.yaml" XDG_STATE_HOME="$TDIR" "$LOADER" get-runtime 2>"$ERR"; RC=$?
assert_exit "exits non-zero" "1" "$RC"
assert_stderr_contains "names max_redispatch" "max_redispatch" "$ERR"
rm -rf "$TDIR" "$ERR"

# === Test 36: validate enforces the dispatch_model charset ===
# Hardened charset ^[A-Za-z0-9][A-Za-z0-9._:@-]*$ : reject whitespace/punct AND a leading
# dash/dot, but accept a normal alias or full id (internal dashes ok), incl. provider
# ids — Bedrock (…-v2:0, colon) and Vertex (…@date, at-sign).
echo "=== Test 36: dispatch_model charset (reject bad / leading-dash, accept valid id) ==="
TDIR=$(mktemp -d); ERR=$(mktemp)

printf 'providers:\n  - id: zai\n    label: "Z"\n    base_url: https://api.z.ai/api/anthropic\n    token: "tkn"\nmodels:\n  - id: zai/glm\n    label: "GLM"\n    model: glm-5.1\nruntime:\n  dispatch_model: "bad model!"\n' > "$TDIR/config.yaml"
MESH_CONFIG="$TDIR/config.yaml" XDG_STATE_HOME="$TDIR" "$LOADER" validate 2>"$ERR"; RC=$?
assert_exit "rejects whitespace/punct dispatch_model" "1" "$RC"
assert_stderr_contains "names dispatch_model" "dispatch_model" "$ERR"

printf 'providers:\n  - id: zai\n    label: "Z"\n    base_url: https://api.z.ai/api/anthropic\n    token: "tkn"\nmodels:\n  - id: zai/glm\n    label: "GLM"\n    model: glm-5.1\nruntime:\n  dispatch_model: "-opus"\n' > "$TDIR/config.yaml"
MESH_CONFIG="$TDIR/config.yaml" XDG_STATE_HOME="$TDIR" "$LOADER" validate 2>"$ERR"; RC=$?
assert_exit "rejects leading-dash dispatch_model" "1" "$RC"

printf 'providers:\n  - id: zai\n    label: "Z"\n    base_url: https://api.z.ai/api/anthropic\n    token: "tkn"\nmodels:\n  - id: zai/glm\n    label: "GLM"\n    model: glm-5.1\nruntime:\n  dispatch_model: "claude-fable-5"\n' > "$TDIR/config.yaml"
MESH_CONFIG="$TDIR/config.yaml" XDG_STATE_HOME="$TDIR" "$LOADER" validate 2>"$ERR"; RC=$?
assert_exit "accepts a valid alias/id (internal dashes ok)" "0" "$RC"

printf 'providers:\n  - id: zai\n    label: "Z"\n    base_url: https://api.z.ai/api/anthropic\n    token: "tkn"\nmodels:\n  - id: zai/glm\n    label: "GLM"\n    model: glm-5.1\nruntime:\n  dispatch_model: "us.anthropic.claude-3-5-sonnet-20241022-v2:0"\n' > "$TDIR/config.yaml"
MESH_CONFIG="$TDIR/config.yaml" XDG_STATE_HOME="$TDIR" "$LOADER" validate 2>"$ERR"; RC=$?
assert_exit "accepts a Bedrock full id (colon ok)" "0" "$RC"

printf 'providers:\n  - id: zai\n    label: "Z"\n    base_url: https://api.z.ai/api/anthropic\n    token: "tkn"\nmodels:\n  - id: zai/glm\n    label: "GLM"\n    model: glm-5.1\nruntime:\n  dispatch_model: "claude-opus-4@20250514"\n' > "$TDIR/config.yaml"
MESH_CONFIG="$TDIR/config.yaml" XDG_STATE_HOME="$TDIR" "$LOADER" validate 2>"$ERR"; RC=$?
assert_exit "accepts a Vertex full id (at-sign ok)" "0" "$RC"

rm -rf "$TDIR" "$ERR"

# === Test 37: get-flag dispatch_model returns the configured value ===
echo "=== Test 37: get-flag dispatch_model returns value ==="
TDIR=$(mktemp -d)
printf 'runtime:\n  dispatch_model: opus\n' > "$TDIR/config.yaml"
GOT=$(MESH_CONFIG="$TDIR/config.yaml" XDG_STATE_HOME="$TDIR" "$LOADER" get-flag dispatch_model)
if [ "$GOT" = "opus" ]; then PASS=$((PASS+1)); echo "  PASS: dispatch_model=opus"; else FAIL=$((FAIL+1)); echo "  FAIL: dispatch_model (expected opus, got '$GOT')"; fi
rm -rf "$TDIR"

# === Test 38: get-flag dispatch_model is empty when the key is absent ===
echo "=== Test 38: get-flag dispatch_model empty when absent ==="
TDIR=$(mktemp -d)
printf 'runtime:\n  default_run_mode: background\n' > "$TDIR/config.yaml"
GOT=$(MESH_CONFIG="$TDIR/config.yaml" XDG_STATE_HOME="$TDIR" "$LOADER" get-flag dispatch_model)
if [ -z "$GOT" ]; then PASS=$((PASS+1)); echo "  PASS: empty when absent"; else FAIL=$((FAIL+1)); echo "  FAIL: expected empty, got '$GOT'"; fi
rm -rf "$TDIR"

# === Test 39: get-runtime surfaces dispatch_model (value, and "" when absent) ===
echo "=== Test 39: get-runtime emits dispatch_model ==="
TDIR=$(mktemp -d)
printf 'runtime:\n  dispatch_model: fable\n' > "$TDIR/config.yaml"
GOT=$(MESH_CONFIG="$TDIR/config.yaml" XDG_STATE_HOME="$TDIR" "$LOADER" get-runtime | jq -r '.dispatch_model')
if [ "$GOT" = "fable" ]; then PASS=$((PASS+1)); echo "  PASS: dispatch_model=fable"; else FAIL=$((FAIL+1)); echo "  FAIL: expected fable, got '$GOT'"; fi
printf 'runtime:\n  default_run_mode: team\n' > "$TDIR/config.yaml"
GOT=$(MESH_CONFIG="$TDIR/config.yaml" XDG_STATE_HOME="$TDIR" "$LOADER" get-runtime | jq -r '.dispatch_model')
if [ -z "$GOT" ]; then PASS=$((PASS+1)); echo "  PASS: dispatch_model defaults to empty"; else FAIL=$((FAIL+1)); echo "  FAIL: expected empty, got '$GOT'"; fi
rm -rf "$TDIR"

# === Test 40: codex.model accepts provider-qualified ids (slash) ===
# codex CLI accepts provider-qualified model ids (e.g. ollama-style `openai/gpt-oss-20b`);
# the model charset must allow "/" — unlike reasoning_level/dispatch_model, which keep the
# stricter charset. Leading "/" stays rejected (leading-alnum anchor).
echo "=== Test 40: codex.model with '/' validates and round-trips ==="
TDIR=$(mktemp -d); ERR=$(mktemp)
sed 's|model: gpt-5.5|model: openai/gpt-oss-20b|' \
    "$FIXTURES/unknown-codex-reasoning.yaml" > "$TDIR/config.yaml"
MESH_CONFIG="$TDIR/config.yaml" XDG_STATE_HOME="$TDIR" "$LOADER" validate 2>"$ERR"; RC=$?
assert_exit "validate exits zero on provider-qualified codex.model" "0" "$RC"
VAL=$(MESH_CONFIG="$TDIR/config.yaml" XDG_STATE_HOME="$TDIR" "$LOADER" get-codex 2>/dev/null)
if [ "$VAL" = "openai/gpt-oss-20b|extreme" ]; then
    PASS=$((PASS+1)); echo "  PASS: get-codex round-trips the slash model"
else
    FAIL=$((FAIL+1)); echo "  FAIL: get-codex printed '$VAL' (expected 'openai/gpt-oss-20b|extreme')"
fi
sed 's|model: gpt-5.5|model: "/gpt-oss"|' \
    "$FIXTURES/unknown-codex-reasoning.yaml" > "$TDIR/config.yaml"
MESH_CONFIG="$TDIR/config.yaml" XDG_STATE_HOME="$TDIR" "$LOADER" validate 2>"$ERR"; RC=$?
assert_exit "still rejects a leading-slash codex.model" "1" "$RC"
assert_stderr_contains "names codex.model charset" "codex.model: must start with" "$ERR"
rm -rf "$TDIR" "$ERR"

# === Test 41: scalar codex:/gemini: sections die cleanly (not raw jq rc=5) ===
# `jq -e '.codex'` gated on truthiness, so `codex: false` skipped validation and then
# crashed cmd_get_codex with a raw jq "Cannot index boolean" (rc=5). The gate must
# type-dispatch: null → absent, object → validate, anything else → clean die.
echo "=== Test 41: codex:/gemini: as non-mapping scalars die cleanly ==="
TDIR=$(mktemp -d); ERR=$(mktemp)
printf 'providers:\n  - id: zai\n    label: "Z"\n    base_url: https://api.z.ai/api/anthropic\n    token: "tkn"\nmodels:\n  - id: zai/glm\n    label: "GLM"\n    model: glm-5.1\ncodex: false\n' > "$TDIR/config.yaml"
MESH_CONFIG="$TDIR/config.yaml" XDG_STATE_HOME="$TDIR" "$LOADER" validate 2>"$ERR"; RC=$?
assert_exit "validate exits 1 on codex: false" "1" "$RC"
assert_stderr_contains "explains the mapping requirement" "codex: must be a mapping" "$ERR"
MESH_CONFIG="$TDIR/config.yaml" XDG_STATE_HOME="$TDIR" "$LOADER" get-codex >/dev/null 2>"$ERR"; RC=$?
assert_exit "get-codex dies cleanly on codex: false (no raw jq rc=5)" "1" "$RC"
printf 'providers:\n  - id: zai\n    label: "Z"\n    base_url: https://api.z.ai/api/anthropic\n    token: "tkn"\nmodels:\n  - id: zai/glm\n    label: "GLM"\n    model: glm-5.1\ngemini: false\n' > "$TDIR/config.yaml"
MESH_CONFIG="$TDIR/config.yaml" XDG_STATE_HOME="$TDIR" "$LOADER" validate 2>"$ERR"; RC=$?
assert_exit "validate exits 1 on gemini: false" "1" "$RC"
assert_stderr_contains "explains the mapping requirement" "gemini: must be a mapping" "$ERR"
MESH_CONFIG="$TDIR/config.yaml" XDG_STATE_HOME="$TDIR" "$LOADER" get-gemini >/dev/null 2>"$ERR"; RC=$?
assert_exit "get-gemini dies cleanly on gemini: false (no raw jq rc=5)" "1" "$RC"
# An explicitly EMPTY key (`codex:` → null) keeps the absent semantics: no error.
printf 'providers:\n  - id: zai\n    label: "Z"\n    base_url: https://api.z.ai/api/anthropic\n    token: "tkn"\nmodels:\n  - id: zai/glm\n    label: "GLM"\n    model: glm-5.1\ncodex:\n' > "$TDIR/config.yaml"
MESH_CONFIG="$TDIR/config.yaml" XDG_STATE_HOME="$TDIR" "$LOADER" validate 2>"$ERR"; RC=$?
assert_exit "validate exits zero on empty 'codex:' key (null = absent)" "0" "$RC"
rm -rf "$TDIR" "$ERR"

# === Test 42: empty config.yaml dies cleanly, without bash arithmetic noise ===
# An empty yaml gives an empty JSON snapshot; jq then emits NOTHING, and the old
# `[ "$count" -gt 0 ]` printed "integer expression expected" before the die message.
echo "=== Test 42: empty config.yaml dies without integer-expression noise ==="
TDIR=$(mktemp -d); ERR=$(mktemp)
: > "$TDIR/config.yaml"
MESH_CONFIG="$TDIR/config.yaml" XDG_STATE_HOME="$TDIR" "$LOADER" validate 2>"$ERR"; RC=$?
assert_exit "validate exits 1 on empty config" "1" "$RC"
assert_stderr_contains "names the empty providers section" "providers: section is empty or missing" "$ERR"
if grep -q -- "integer expression" "$ERR"; then
    FAIL=$((FAIL+1)); echo "  FAIL: bash arithmetic noise leaked to stderr"
    echo "    stderr was:"; sed 's/^/      /' "$ERR"
else
    PASS=$((PASS+1)); echo "  PASS: stderr free of integer-expression noise"
fi
rm -rf "$TDIR" "$ERR"

# === Test 43: get-runtime exposes timeouts (watch loops read global_sec via the loader) ===
# The mesh-review/mesh-design-review disk-watch bounds itself by runtime.timeouts.global_sec
# "via the loader" — so get-runtime must actually emit the timeouts block (defaults match
# cmd_export: single_run_sec 1800, stall_sec 600, global_sec 3600, max_retries 2).
echo "=== Test 43: get-runtime emits timeouts with export-parity defaults ==="
TDIR=$(mktemp -d)
printf 'runtime:\n  timeouts:\n    global_sec: 7200\n' > "$TDIR/config.yaml"
GOT=$(MESH_CONFIG="$TDIR/config.yaml" XDG_STATE_HOME="$TDIR" "$LOADER" get-runtime | jq -r '.timeouts.global_sec')
if [ "$GOT" = "7200" ]; then PASS=$((PASS+1)); echo "  PASS: configured global_sec=7200"; else FAIL=$((FAIL+1)); echo "  FAIL: global_sec (expected 7200, got '$GOT')"; fi
printf 'runtime:\n  default_run_mode: background\n' > "$TDIR/config.yaml"
GOT=$(MESH_CONFIG="$TDIR/config.yaml" XDG_STATE_HOME="$TDIR" "$LOADER" get-runtime | jq -r '[.timeouts.single_run_sec, .timeouts.stall_sec, .timeouts.global_sec, .timeouts.max_retries] | join(",")')
if [ "$GOT" = "1800,600,3600,2" ]; then PASS=$((PASS+1)); echo "  PASS: defaults 1800,600,3600,2"; else FAIL=$((FAIL+1)); echo "  FAIL: timeout defaults (got '$GOT')"; fi
rm -rf "$TDIR"

# === Test 44: export still validates its OWN sections (regression guard) ===
# cmd_export's scoping (fix wave 1) must not be read as "export skips validation":
# deleting validate_providers/validate_models/validate_runtime from cmd_export would
# keep the whole suite green without these asserts (final-review + wave-5 finding).
echo "=== Test 44: export fails on broken providers/models/runtime sections ==="
TDIR=$(mktemp -d); ERR=$(mktemp)
cp "$FIXTURES/invalid-provider-bad-url.yaml" "$TDIR/config.yaml"
MESH_CONFIG="$TDIR/config.yaml" XDG_STATE_HOME="$TDIR" "$LOADER" export zai/glm >/dev/null 2>"$ERR"; RC=$?
assert_exit "export exits 1 on invalid provider base_url" "1" "$RC"
assert_stderr_contains "names the invalid URL" "invalid URL" "$ERR"
cp "$FIXTURES/invalid-model-duplicate.yaml" "$TDIR/config.yaml"
MESH_CONFIG="$TDIR/config.yaml" XDG_STATE_HOME="$TDIR" "$LOADER" export zai/glm >/dev/null 2>"$ERR"; RC=$?
assert_exit "export exits 1 on duplicate model id" "1" "$RC"
assert_stderr_contains "names the duplicate id" "duplicate id" "$ERR"
cp "$FIXTURES/invalid-runtime-timeout-zero.yaml" "$TDIR/config.yaml"
MESH_CONFIG="$TDIR/config.yaml" XDG_STATE_HOME="$TDIR" "$LOADER" export zai/glm >/dev/null 2>"$ERR"; RC=$?
assert_exit "export exits 1 on zero runtime timeout" "1" "$RC"
assert_stderr_contains "names the positive-integer rule" "positive integer" "$ERR"
rm -rf "$TDIR" "$ERR"

# === Test 45: unquoted YAML-1.1-style `off` parses as a STRING with kislyuk-yq ===
# Locks the empirical behavior the validate_codex comment describes (fix wave 5):
# `reasoning_level: off` reaches the validator as the string "off" and takes the
# warn-and-pass-through path — NOT the non-string type die (that path is for
# true/false/numbers, covered by Test 41 / 7i).
echo "=== Test 45: reasoning_level: off warns and passes through as a string ==="
TDIR=$(mktemp -d); ERR=$(mktemp)
sed 's/reasoning_level: extreme.*/reasoning_level: off/' \
    "$FIXTURES/unknown-codex-reasoning.yaml" > "$TDIR/config.yaml"
MESH_CONFIG="$TDIR/config.yaml" XDG_STATE_HOME="$TDIR" "$LOADER" validate 2>"$ERR"; RC=$?
assert_exit "validate exits zero on unquoted 'off'" "0" "$RC"
assert_stderr_contains "warns about the unknown level" 'unknown value "off"' "$ERR"
VAL=$(MESH_CONFIG="$TDIR/config.yaml" XDG_STATE_HOME="$TDIR" "$LOADER" get-codex 2>/dev/null)
if [ "$VAL" = "gpt-5.5|off" ]; then
    PASS=$((PASS+1)); echo "  PASS: get-codex passes 'off' through as a string"
else
    FAIL=$((FAIL+1)); echo "  FAIL: get-codex printed '$VAL' (expected 'gpt-5.5|off')"
fi
rm -rf "$TDIR" "$ERR"

# === Test 46: scalar runtime:/runtime.timeouts sections die cleanly (not raw jq rc=5) ===
# Same class as Test 41 (fix wave 6, Codex PR-review P2): `jq -e '.runtime'` gated on
# truthiness, so `runtime: false` passed validate SILENTLY, and a non-mapping
# `runtime.timeouts` passed rc=0 while spraying raw jq "Cannot index boolean" noise;
# both then crashed cmd_get_runtime (rc=5) — which the mesh-review/mesh-design-review
# watch loops call for timeouts.global_sec. The gate must type-dispatch like the
# codex:/gemini: ones: null → absent, object → validate, anything else → clean die.
echo "=== Test 46: runtime:/runtime.timeouts as non-mapping scalars die cleanly ==="
TDIR=$(mktemp -d); ERR=$(mktemp)
printf 'providers:\n  - id: zai\n    label: "Z"\n    base_url: https://api.z.ai/api/anthropic\n    token: "tkn"\nmodels:\n  - id: zai/glm\n    label: "GLM"\n    model: glm-5.1\nruntime: false\n' > "$TDIR/config.yaml"
MESH_CONFIG="$TDIR/config.yaml" XDG_STATE_HOME="$TDIR" "$LOADER" validate 2>"$ERR"; RC=$?
assert_exit "validate exits 1 on runtime: false" "1" "$RC"
assert_stderr_contains "explains the mapping requirement" "runtime: must be a mapping" "$ERR"
MESH_CONFIG="$TDIR/config.yaml" XDG_STATE_HOME="$TDIR" "$LOADER" get-runtime >/dev/null 2>"$ERR"; RC=$?
assert_exit "get-runtime dies cleanly on runtime: false (no raw jq rc=5)" "1" "$RC"
printf 'providers:\n  - id: zai\n    label: "Z"\n    base_url: https://api.z.ai/api/anthropic\n    token: "tkn"\nmodels:\n  - id: zai/glm\n    label: "GLM"\n    model: glm-5.1\nruntime:\n  timeouts: false\n' > "$TDIR/config.yaml"
MESH_CONFIG="$TDIR/config.yaml" XDG_STATE_HOME="$TDIR" "$LOADER" validate 2>"$ERR"; RC=$?
assert_exit "validate exits 1 on runtime.timeouts: false" "1" "$RC"
assert_stderr_contains "explains the mapping requirement" "runtime.timeouts: must be a mapping" "$ERR"
if grep -q -- "Cannot index" "$ERR"; then
    FAIL=$((FAIL+1)); echo "  FAIL: raw jq indexing noise leaked to validate stderr"
    echo "    stderr was:"; sed 's/^/      /' "$ERR"
else
    PASS=$((PASS+1)); echo "  PASS: validate stderr free of raw jq indexing noise"
fi
MESH_CONFIG="$TDIR/config.yaml" XDG_STATE_HOME="$TDIR" "$LOADER" get-runtime >/dev/null 2>"$ERR"; RC=$?
assert_exit "get-runtime dies cleanly on runtime.timeouts: false (no raw jq rc=5)" "1" "$RC"
# Explicitly EMPTY keys (`runtime:` / `timeouts:` → null) keep the absent semantics.
printf 'providers:\n  - id: zai\n    label: "Z"\n    base_url: https://api.z.ai/api/anthropic\n    token: "tkn"\nmodels:\n  - id: zai/glm\n    label: "GLM"\n    model: glm-5.1\nruntime:\n' > "$TDIR/config.yaml"
MESH_CONFIG="$TDIR/config.yaml" XDG_STATE_HOME="$TDIR" "$LOADER" validate 2>"$ERR"; RC=$?
assert_exit "validate exits zero on empty 'runtime:' key (null = absent)" "0" "$RC"
printf 'providers:\n  - id: zai\n    label: "Z"\n    base_url: https://api.z.ai/api/anthropic\n    token: "tkn"\nmodels:\n  - id: zai/glm\n    label: "GLM"\n    model: glm-5.1\nruntime:\n  timeouts:\n' > "$TDIR/config.yaml"
MESH_CONFIG="$TDIR/config.yaml" XDG_STATE_HOME="$TDIR" "$LOADER" validate 2>"$ERR"; RC=$?
assert_exit "validate exits zero on empty 'timeouts:' key (null = absent)" "0" "$RC"
rm -rf "$TDIR" "$ERR"

# === Test 47: claude: catalog — type gate, charset, duplicates ===
# Same class of gate as Test 41 (codex:/gemini:): a scalar `claude:` section must die
# cleanly instead of crashing the getters with a raw jq "Cannot index boolean" (rc=5).
# The catalog is charset-validated with IDENT_RE (no enum — forward-compat), and
# duplicates are rejected because two reviewers under one name are indistinguishable
# in the dedup tables.
echo "=== Test 47: claude: catalog validation ==="
TDIR=$(mktemp -d); ERR=$(mktemp)
BASE=$(printf 'providers:\n  - id: zai\n    label: "Z"\n    base_url: https://api.z.ai/api/anthropic\n    token: "tkn"\nmodels:\n  - id: zai/glm\n    label: "GLM"\n    model: glm-5.1\n')

{ printf '%s\n' "$BASE"; printf 'claude: false\n'; } > "$TDIR/config.yaml"
MESH_CONFIG="$TDIR/config.yaml" XDG_STATE_HOME="$TDIR" "$LOADER" validate 2>"$ERR"; RC=$?
assert_exit "validate exits 1 on claude: false" "1" "$RC"
assert_stderr_contains "explains the mapping requirement" "claude: must be a mapping" "$ERR"
if grep -q -- "Cannot index" "$ERR"; then
    FAIL=$((FAIL+1)); echo "  FAIL: raw jq indexing noise leaked to validate stderr"
    echo "    stderr was:"; sed 's/^/      /' "$ERR"
else
    PASS=$((PASS+1)); echo "  PASS: validate stderr free of raw jq indexing noise"
fi

{ printf '%s\n' "$BASE"; printf 'claude:\n  models: opus\n'; } > "$TDIR/config.yaml"
MESH_CONFIG="$TDIR/config.yaml" XDG_STATE_HOME="$TDIR" "$LOADER" validate 2>"$ERR"; RC=$?
assert_exit "rejects a scalar claude.models" "1" "$RC"
assert_stderr_contains "explains the list requirement" "claude.models: must be a list" "$ERR"

{ printf '%s\n' "$BASE"; printf 'claude:\n  models:\n    - 5\n'; } > "$TDIR/config.yaml"
MESH_CONFIG="$TDIR/config.yaml" XDG_STATE_HOME="$TDIR" "$LOADER" validate 2>"$ERR"; RC=$?
assert_exit "rejects a non-string catalog entry" "1" "$RC"
assert_stderr_contains "explains the string requirement" "must be a string" "$ERR"

{ printf '%s\n' "$BASE"; printf 'claude:\n  models:\n    - "-opus"\n'; } > "$TDIR/config.yaml"
MESH_CONFIG="$TDIR/config.yaml" XDG_STATE_HOME="$TDIR" "$LOADER" validate 2>"$ERR"; RC=$?
assert_exit "rejects a leading-dash catalog entry" "1" "$RC"
assert_stderr_contains "names the charset rule" "claude.models\[0\]: must start with" "$ERR"

# A space INSIDE the value. Unquoted YAML flow style makes this easy to write by accident
# (`models: [opus, claude fable]` is two entries, the second with a space), and an entry
# with a space would be word-split by the membership globs downstream.
{ printf '%s\n' "$BASE"; printf 'claude:\n  models: [opus, "claude fable"]\n'; } > "$TDIR/config.yaml"
MESH_CONFIG="$TDIR/config.yaml" XDG_STATE_HOME="$TDIR" "$LOADER" validate 2>"$ERR"; RC=$?
assert_exit "rejects a catalog entry containing a space" "1" "$RC"
assert_stderr_contains "names the charset rule for the space" "claude.models\[1\]" "$ERR"

{ printf '%s\n' "$BASE"; printf 'claude:\n  models: [opus, fable, opus]\n'; } > "$TDIR/config.yaml"
MESH_CONFIG="$TDIR/config.yaml" XDG_STATE_HOME="$TDIR" "$LOADER" validate 2>"$ERR"; RC=$?
assert_exit "rejects a duplicate catalog entry" "1" "$RC"
assert_stderr_contains "names the duplicate" "duplicate model" "$ERR"

{ printf '%s\n' "$BASE"; printf 'claude:\n  models: [opus, fable, "claude-fable-5", "us.anthropic.claude-3-5-sonnet-20241022-v2:0"]\n'; } > "$TDIR/config.yaml"
MESH_CONFIG="$TDIR/config.yaml" XDG_STATE_HOME="$TDIR" "$LOADER" validate 2>"$ERR"; RC=$?
assert_exit "accepts aliases and full ids (dashes, dots, colon)" "0" "$RC"

# An explicitly EMPTY key (`claude:` → null) keeps the absent semantics, like codex:.
{ printf '%s\n' "$BASE"; printf 'claude:\n'; } > "$TDIR/config.yaml"
MESH_CONFIG="$TDIR/config.yaml" XDG_STATE_HOME="$TDIR" "$LOADER" validate 2>"$ERR"; RC=$?
assert_exit "validate exits zero on empty 'claude:' key (null = absent)" "0" "$RC"

# An empty list is legal and simply means "no catalog" (mirrors defaults.*.models).
{ printf '%s\n' "$BASE"; printf 'claude:\n  models: []\n'; } > "$TDIR/config.yaml"
MESH_CONFIG="$TDIR/config.yaml" XDG_STATE_HOME="$TDIR" "$LOADER" validate 2>"$ERR"; RC=$?
assert_exit "validate exits zero on an empty claude.models list" "0" "$RC"

# A mapping with no models key at all. `.claude.models | type` is "null" here, so this is
# deliberately equivalent to "no section" — UNLIKE codex:/gemini:, where a section missing
# its `model:` key is a hard error. Pinned by a test so a future maintainer does not
# "restore" the missing check.
{ printf '%s\n' "$BASE"; printf 'claude: {}\n'; } > "$TDIR/config.yaml"
MESH_CONFIG="$TDIR/config.yaml" XDG_STATE_HOME="$TDIR" "$LOADER" validate 2>"$ERR"; RC=$?
assert_exit "treats 'claude: {}' as no catalog, not as an error" "0" "$RC"

rm -rf "$TDIR" "$ERR"

# === Test 48: defaults.<preset>.claude_models validation ===
# Membership mirrors defaults.*.models ⊂ models[].id. The "claude missing from builtin"
# rule is fail-closed on purpose: a silently ignored claude_models list is exactly the
# bug this feature fixes in mesh-design-review, so it must never be introduced here.
echo "=== Test 48: defaults.claude_models validation ==="
TDIR=$(mktemp -d); ERR=$(mktemp)
BASE=$(printf 'providers:\n  - id: zai\n    label: "Z"\n    base_url: https://api.z.ai/api/anthropic\n    token: "tkn"\nmodels:\n  - id: zai/glm\n    label: "GLM"\n    model: glm-5.1\n')
CATALOG=$(printf 'claude:\n  models: [opus, fable]\n')

{ printf '%s\n' "$BASE"; printf '%s\n' "$CATALOG"; printf 'defaults:\n  code_review:\n    builtin: [claude]\n    claude_models: opus\n'; } > "$TDIR/config.yaml"
MESH_CONFIG="$TDIR/config.yaml" XDG_STATE_HOME="$TDIR" "$LOADER" validate 2>"$ERR"; RC=$?
assert_exit "rejects a scalar claude_models" "1" "$RC"
assert_stderr_contains "explains the list requirement" "claude_models: must be a list" "$ERR"

{ printf '%s\n' "$BASE"; printf '%s\n' "$CATALOG"; printf 'defaults:\n  code_review:\n    builtin: [claude]\n    claude_models: [opus, sonnet]\n'; } > "$TDIR/config.yaml"
MESH_CONFIG="$TDIR/config.yaml" XDG_STATE_HOME="$TDIR" "$LOADER" validate 2>"$ERR"; RC=$?
assert_exit "rejects a model absent from the catalog" "1" "$RC"
assert_stderr_contains "names the unknown model" 'unknown claude model "sonnet"' "$ERR"

# No catalog at all: every entry is "unknown", and the message must point at the catalog.
{ printf '%s\n' "$BASE"; printf 'defaults:\n  code_review:\n    builtin: [claude]\n    claude_models: [opus]\n'; } > "$TDIR/config.yaml"
MESH_CONFIG="$TDIR/config.yaml" XDG_STATE_HOME="$TDIR" "$LOADER" validate 2>"$ERR"; RC=$?
assert_exit "rejects claude_models with no claude.models catalog" "1" "$RC"
assert_stderr_contains "points at the catalog" "claude.models catalog" "$ERR"

{ printf '%s\n' "$BASE"; printf '%s\n' "$CATALOG"; printf 'defaults:\n  code_review:\n    builtin: [codex]\n    claude_models: [opus]\ncodex:\n  model: gpt-5.5\n'; } > "$TDIR/config.yaml"
MESH_CONFIG="$TDIR/config.yaml" XDG_STATE_HOME="$TDIR" "$LOADER" validate 2>"$ERR"; RC=$?
assert_exit "rejects claude_models without claude in builtin" "1" "$RC"
assert_stderr_contains "names the missing builtin entry" 'is missing from defaults.code_review.builtin' "$ERR"

{ printf '%s\n' "$BASE"; printf '%s\n' "$CATALOG"; printf 'defaults:\n  code_review:\n    builtin: [claude]\n    claude_models: [opus, opus]\n'; } > "$TDIR/config.yaml"
MESH_CONFIG="$TDIR/config.yaml" XDG_STATE_HOME="$TDIR" "$LOADER" validate 2>"$ERR"; RC=$?
assert_exit "rejects a duplicate claude_models entry" "1" "$RC"
assert_stderr_contains "names the duplicate" 'duplicate model "opus"' "$ERR"

# Element type gate. Without it `jq -r` stringifies the value and the membership test
# compares that string, so a catalog of ["5","true"] would accept a preset of [5, true].
{ printf '%s\n' "$BASE"; printf 'claude:\n  models: ["5", "true"]\n'; printf 'defaults:\n  code_review:\n    builtin: [claude]\n    claude_models: [5, true]\n'; } > "$TDIR/config.yaml"
MESH_CONFIG="$TDIR/config.yaml" XDG_STATE_HOME="$TDIR" "$LOADER" validate 2>"$ERR"; RC=$?
assert_exit "rejects non-string claude_models entries" "1" "$RC"
assert_stderr_contains "explains the string requirement" "must be a string" "$ERR"

# The empty-string entry is the sharp one: `tr '\n' ' '` leaves $claude_catalog EMPTY
# when there is no catalog, so " $claude_catalog " is "  " and the glob *"  "*
# MATCHES an empty $cmv — the entry sails through membership with no catalog at all.
{ printf '%s\n' "$BASE"; printf 'defaults:\n  code_review:\n    builtin: [claude]\n    claude_models: [""]\n'; } > "$TDIR/config.yaml"
MESH_CONFIG="$TDIR/config.yaml" XDG_STATE_HOME="$TDIR" "$LOADER" validate 2>"$ERR"; RC=$?
assert_exit "rejects an empty claude_models entry (no catalog)" "1" "$RC"
assert_stderr_contains "names it as empty, not as unknown" "empty value" "$ERR"

# Charset gate. Membership is a substring match against the space-joined catalog, so a
# multi-token value whose words are ADJACENT catalog members would span it: a missing
# comma in `["opus fable"]` is ONE string, it matched " opus fable " inside " opus fable "
# and validated clean (get-defaults then emitted the bogus entry verbatim). The catalog
# side already rejects the identical string via IDENT_RE (Test 47) — both sides now do.
{ printf '%s\n' "$BASE"; printf '%s\n' "$CATALOG"; printf 'defaults:\n  code_review:\n    builtin: [claude]\n    claude_models: ["opus fable"]\n'; } > "$TDIR/config.yaml"
MESH_CONFIG="$TDIR/config.yaml" XDG_STATE_HOME="$TDIR" "$LOADER" validate 2>"$ERR"; RC=$?
assert_exit "rejects a space-spanning claude_models entry (missing comma)" "1" "$RC"
assert_stderr_contains "reports it as a charset violation, not as unknown" 'must start with a letter/digit' "$ERR"

# design_review is validated by the same loop.
{ printf '%s\n' "$BASE"; printf '%s\n' "$CATALOG"; printf 'defaults:\n  design_review:\n    builtin: [claude]\n    claude_models: [sonnet]\n'; } > "$TDIR/config.yaml"
MESH_CONFIG="$TDIR/config.yaml" XDG_STATE_HOME="$TDIR" "$LOADER" validate 2>"$ERR"; RC=$?
assert_exit "applies the same rules to design_review" "1" "$RC"
assert_stderr_contains "names the design_review preset" "defaults.design_review.claude_models" "$ERR"

# Happy path: catalog wider than the presets, presets differing from each other.
{ printf '%s\n' "$BASE"; printf 'claude:\n  models: [opus, sonnet, fable]\n'; printf 'defaults:\n  code_review:\n    builtin: [claude]\n    claude_models: [opus, fable]\n  design_review:\n    builtin: [claude]\n    claude_models: [opus]\n'; } > "$TDIR/config.yaml"
MESH_CONFIG="$TDIR/config.yaml" XDG_STATE_HOME="$TDIR" "$LOADER" validate 2>"$ERR"; RC=$?
assert_exit "accepts differing per-preset subsets of a wider catalog" "0" "$RC"
# The double call is now real: validate_all calls validate_claude directly and
# validate_defaults calls it again. A `warn` added inside it would print twice with
# nothing catching it, so pin the silence.
if [ ! -s "$ERR" ]; then
    PASS=$((PASS+1)); echo "  PASS: a valid catalog + presets produce no stderr (validate_claude stays side-effect-free under its double call)"
else
    FAIL=$((FAIL+1)); echo "  FAIL: expected empty stderr, got:"; sed 's/^/      /' "$ERR"
fi

# Back-compat: claude in builtin with NO claude_models stays valid (fallback = 1 reviewer).
{ printf '%s\n' "$BASE"; printf '%s\n' "$CATALOG"; printf 'defaults:\n  code_review:\n    builtin: [claude]\n'; } > "$TDIR/config.yaml"
MESH_CONFIG="$TDIR/config.yaml" XDG_STATE_HOME="$TDIR" "$LOADER" validate 2>"$ERR"; RC=$?
assert_exit "accepts builtin claude with no claude_models" "0" "$RC"

rm -rf "$TDIR" "$ERR"

# === Test 49: get-flag has_claude_models + list-claude-models ===
# Unlike has_codex/has_gemini (plain section-existence probes) these read INSIDE the
# section, so they must validate first — a raw jq read on `claude: false` would exit 5
# with "Cannot index boolean" and the orchestrators would surface that as garbage.
echo "=== Test 49: has_claude_models / list-claude-models ==="
TDIR=$(mktemp -d); ERR=$(mktemp)
BASE=$(printf 'providers:\n  - id: zai\n    label: "Z"\n    base_url: https://api.z.ai/api/anthropic\n    token: "tkn"\nmodels:\n  - id: zai/glm\n    label: "GLM"\n    model: glm-5.1\n')

{ printf '%s\n' "$BASE"; printf 'claude:\n  models: [opus, fable]\n'; } > "$TDIR/config.yaml"
GOT=$(MESH_CONFIG="$TDIR/config.yaml" XDG_STATE_HOME="$TDIR" "$LOADER" get-flag has_claude_models)
if [ "$GOT" = "1" ]; then PASS=$((PASS+1)); echo "  PASS: has_claude_models=1 with a catalog"; else FAIL=$((FAIL+1)); echo "  FAIL: has_claude_models (expected 1, got '$GOT')"; fi
GOT=$(MESH_CONFIG="$TDIR/config.yaml" XDG_STATE_HOME="$TDIR" "$LOADER" list-claude-models | tr '\n' ',')
if [ "$GOT" = "opus,fable," ]; then PASS=$((PASS+1)); echo "  PASS: list-claude-models keeps config order"; else FAIL=$((FAIL+1)); echo "  FAIL: list-claude-models (expected 'opus,fable,', got '$GOT')"; fi

{ printf '%s\n' "$BASE"; } > "$TDIR/config.yaml"
GOT=$(MESH_CONFIG="$TDIR/config.yaml" XDG_STATE_HOME="$TDIR" "$LOADER" get-flag has_claude_models)
if [ "$GOT" = "0" ]; then PASS=$((PASS+1)); echo "  PASS: has_claude_models=0 with no section"; else FAIL=$((FAIL+1)); echo "  FAIL: has_claude_models (expected 0, got '$GOT')"; fi
MESH_CONFIG="$TDIR/config.yaml" XDG_STATE_HOME="$TDIR" "$LOADER" list-claude-models >"$TDIR/out" 2>"$ERR"; RC=$?
assert_exit "list-claude-models exits 0 with no catalog" "0" "$RC"
if [ ! -s "$TDIR/out" ]; then PASS=$((PASS+1)); echo "  PASS: list-claude-models prints nothing with no catalog"; else FAIL=$((FAIL+1)); echo "  FAIL: expected empty output, got '$(cat "$TDIR/out")'"; fi

{ printf '%s\n' "$BASE"; printf 'claude:\n  models: []\n'; } > "$TDIR/config.yaml"
GOT=$(MESH_CONFIG="$TDIR/config.yaml" XDG_STATE_HOME="$TDIR" "$LOADER" get-flag has_claude_models)
if [ "$GOT" = "0" ]; then PASS=$((PASS+1)); echo "  PASS: has_claude_models=0 on an empty list"; else FAIL=$((FAIL+1)); echo "  FAIL: has_claude_models (expected 0, got '$GOT')"; fi

# A mapping with no models key — same "no catalog" semantics as an absent section.
{ printf '%s\n' "$BASE"; printf 'claude: {}\n'; } > "$TDIR/config.yaml"
GOT=$(MESH_CONFIG="$TDIR/config.yaml" XDG_STATE_HOME="$TDIR" "$LOADER" get-flag has_claude_models)
if [ "$GOT" = "0" ]; then PASS=$((PASS+1)); echo "  PASS: has_claude_models=0 for 'claude: {}'"; else FAIL=$((FAIL+1)); echo "  FAIL: has_claude_models (expected 0, got '$GOT')"; fi
MESH_CONFIG="$TDIR/config.yaml" XDG_STATE_HOME="$TDIR" "$LOADER" list-claude-models >"$TDIR/out" 2>"$ERR"; RC=$?
assert_exit "list-claude-models exits 0 for 'claude: {}'" "0" "$RC"

{ printf '%s\n' "$BASE"; printf 'claude: false\n'; } > "$TDIR/config.yaml"
MESH_CONFIG="$TDIR/config.yaml" XDG_STATE_HOME="$TDIR" "$LOADER" get-flag has_claude_models >/dev/null 2>"$ERR"; RC=$?
assert_exit "get-flag dies cleanly on claude: false (no raw jq rc=5)" "1" "$RC"
assert_stderr_contains "explains the mapping requirement" "claude: must be a mapping" "$ERR"
MESH_CONFIG="$TDIR/config.yaml" XDG_STATE_HOME="$TDIR" "$LOADER" list-claude-models >/dev/null 2>"$ERR"; RC=$?
assert_exit "list-claude-models dies cleanly on claude: false" "1" "$RC"

{ printf '%s\n' "$BASE"; } > "$TDIR/config.yaml"
MESH_CONFIG="$TDIR/config.yaml" XDG_STATE_HOME="$TDIR" "$LOADER" get-flag no_such_flag >/dev/null 2>"$ERR"; RC=$?
assert_exit "unknown get-flag feature still dies" "1" "$RC"
assert_stderr_contains "lists has_claude_models among valid features" "has_claude_models" "$ERR"

rm -rf "$TDIR" "$ERR"

# === Test 50: get-defaults emits claude_models ===
# The orchestrators read the preset through this single JSON object; a missing key would
# make them fall back to "no claude models" and silently under-dispatch.
echo "=== Test 50: get-defaults emits claude_models ==="
TDIR=$(mktemp -d)
BASE=$(printf 'providers:\n  - id: zai\n    label: "Z"\n    base_url: https://api.z.ai/api/anthropic\n    token: "tkn"\nmodels:\n  - id: zai/glm\n    label: "GLM"\n    model: glm-5.1\n')

{ printf '%s\n' "$BASE"; printf 'claude:\n  models: [opus, sonnet, fable]\n'; printf 'defaults:\n  code_review:\n    builtin: [claude]\n    claude_models: [opus, fable]\n  design_review:\n    builtin: [claude]\n    claude_models: [opus]\n'; } > "$TDIR/config.yaml"
GOT=$(MESH_CONFIG="$TDIR/config.yaml" XDG_STATE_HOME="$TDIR" "$LOADER" get-defaults code_review | jq -r '.claude_models | join(",")')
if [ "$GOT" = "opus,fable" ]; then PASS=$((PASS+1)); echo "  PASS: code_review claude_models=opus,fable"; else FAIL=$((FAIL+1)); echo "  FAIL: code_review claude_models (expected 'opus,fable', got '$GOT')"; fi
GOT=$(MESH_CONFIG="$TDIR/config.yaml" XDG_STATE_HOME="$TDIR" "$LOADER" get-defaults design_review | jq -r '.claude_models | join(",")')
if [ "$GOT" = "opus" ]; then PASS=$((PASS+1)); echo "  PASS: design_review claude_models=opus"; else FAIL=$((FAIL+1)); echo "  FAIL: design_review claude_models (expected 'opus', got '$GOT')"; fi

# Absent key → an empty list that is PRESENT in the object, never a missing key and never
# null. Tested with has() on purpose: `null | length` is 0 in jq, so a length check would
# pass even when the field is absent entirely.
{ printf '%s\n' "$BASE"; printf 'defaults:\n  code_review:\n    builtin: [claude]\n'; } > "$TDIR/config.yaml"
GOT=$(MESH_CONFIG="$TDIR/config.yaml" XDG_STATE_HOME="$TDIR" "$LOADER" get-defaults code_review | jq -r 'has("claude_models")')
if [ "$GOT" = "true" ]; then PASS=$((PASS+1)); echo "  PASS: claude_models key always present"; else FAIL=$((FAIL+1)); echo "  FAIL: expected has(claude_models)=true, got '$GOT'"; fi
GOT=$(MESH_CONFIG="$TDIR/config.yaml" XDG_STATE_HOME="$TDIR" "$LOADER" get-defaults code_review | jq -r '.claude_models | type')
if [ "$GOT" = "array" ]; then PASS=$((PASS+1)); echo "  PASS: absent claude_models becomes []"; else FAIL=$((FAIL+1)); echo "  FAIL: expected an array, got '$GOT'"; fi
GOT=$(MESH_CONFIG="$TDIR/config.yaml" XDG_STATE_HOME="$TDIR" "$LOADER" get-defaults code_review | jq -r '.builtin | join(",")')
if [ "$GOT" = "claude" ]; then PASS=$((PASS+1)); echo "  PASS: existing get-defaults fields intact"; else FAIL=$((FAIL+1)); echo "  FAIL: builtin (expected 'claude', got '$GOT')"; fi

# The clean-death path. cmd_get_defaults is the only real consumer of the validate_claude
# call inside validate_defaults: with a scalar `claude:` next to a `defaults:` section it
# must die with the validator's message, not with raw jq indexing noise. Deleting that call
# leaves the rest of the suite green (validate_all calls validate_claude itself one line
# earlier), so the call is pinned here. Unpiped on purpose — rc through a pipe is the
# pipeline's rc, not the loader's.
ERR=$(mktemp)
{ printf '%s\n' "$BASE"; printf 'claude: false\n'; printf 'defaults:\n  code_review:\n    builtin: [claude]\n'; } > "$TDIR/config.yaml"
MESH_CONFIG="$TDIR/config.yaml" XDG_STATE_HOME="$TDIR" "$LOADER" get-defaults code_review >/dev/null 2>"$ERR"; RC=$?
assert_exit "get-defaults dies cleanly on claude: false (no raw jq rc=5)" "1" "$RC"
assert_stderr_contains "explains the mapping requirement" "claude: must be a mapping" "$ERR"
if grep -q -- "Cannot index" "$ERR"; then
    FAIL=$((FAIL+1)); echo "  FAIL: raw jq indexing noise leaked to get-defaults stderr"
    echo "    stderr was:"; sed 's/^/      /' "$ERR"
else
    PASS=$((PASS+1)); echo "  PASS: get-defaults stderr free of raw jq indexing noise"
fi

rm -rf "$TDIR" "$ERR"

# === Test 51: config.example.yaml documents the claude catalog end-to-end ===
# Guards the worked example itself: the catalog must be wider than the presets (so the
# ★-recommended vs available distinction is demonstrable) and the two presets must differ
# (so the per-preset capability is demonstrable). A doc-only example that silently loses
# these properties would mis-teach every new user.
echo "=== Test 51: config.example.yaml claude catalog round-trip ==="
TDIR=$(mktemp -d)
cp "$TESTS_DIR/../../../config.example.yaml" "$TDIR/config.yaml"
CATALOG=$(MESH_CONFIG="$TDIR/config.yaml" XDG_STATE_HOME="$TDIR" "$LOADER" list-claude-models | tr '\n' ',')
if [ "$CATALOG" = "opus,sonnet,fable," ]; then PASS=$((PASS+1)); echo "  PASS: example catalog is opus,sonnet,fable"; else FAIL=$((FAIL+1)); echo "  FAIL: example catalog (expected 'opus,sonnet,fable,', got '$CATALOG')"; fi
GOT=$(MESH_CONFIG="$TDIR/config.yaml" XDG_STATE_HOME="$TDIR" "$LOADER" get-flag has_claude_models)
if [ "$GOT" = "1" ]; then PASS=$((PASS+1)); echo "  PASS: has_claude_models=1 for the example"; else FAIL=$((FAIL+1)); echo "  FAIL: has_claude_models (expected 1, got '$GOT')"; fi
CR=$(MESH_CONFIG="$TDIR/config.yaml" XDG_STATE_HOME="$TDIR" "$LOADER" get-defaults code_review | jq -r '.claude_models | join(",")')
DR=$(MESH_CONFIG="$TDIR/config.yaml" XDG_STATE_HOME="$TDIR" "$LOADER" get-defaults design_review | jq -r '.claude_models | join(",")')
if [ "$CR" = "opus,fable" ]; then PASS=$((PASS+1)); echo "  PASS: example code_review claude_models=opus,fable"; else FAIL=$((FAIL+1)); echo "  FAIL: code_review claude_models (expected 'opus,fable', got '$CR')"; fi
if [ "$DR" = "opus" ]; then PASS=$((PASS+1)); echo "  PASS: example design_review claude_models=opus"; else FAIL=$((FAIL+1)); echo "  FAIL: design_review claude_models (expected 'opus', got '$DR')"; fi
if [ "$CR" != "$DR" ]; then PASS=$((PASS+1)); echo "  PASS: example presets demonstrate differing sets"; else FAIL=$((FAIL+1)); echo "  FAIL: example presets must differ to demonstrate the feature"; fi
# Task 4 rewrote cmd_get_defaults as one jq object literal, leaving `models` and `run_mode`
# with no regression coverage anywhere in this suite. Pin both here, on the example: run_mode
# must stay `background` for code_review and keep defaulting to null for design_review (which
# has no run_mode field at all), and neither preset's models list may be lost.
GOT=$(MESH_CONFIG="$TDIR/config.yaml" XDG_STATE_HOME="$TDIR" "$LOADER" get-defaults code_review | jq -r '[(.run_mode|tostring), (.models|length|tostring)] | join(",")')
if [ "$GOT" = "background,4" ]; then PASS=$((PASS+1)); echo "  PASS: example code_review keeps run_mode=background + 4 models"; else FAIL=$((FAIL+1)); echo "  FAIL: code_review run_mode/models count (expected 'background,4', got '$GOT')"; fi
GOT=$(MESH_CONFIG="$TDIR/config.yaml" XDG_STATE_HOME="$TDIR" "$LOADER" get-defaults design_review | jq -r '[(.run_mode|tostring), (.models|length|tostring)] | join(",")')
if [ "$GOT" = "null,4" ]; then PASS=$((PASS+1)); echo "  PASS: example design_review keeps run_mode=null + 4 models"; else FAIL=$((FAIL+1)); echo "  FAIL: design_review run_mode/models count (expected 'null,4', got '$GOT')"; fi
rm -rf "$TDIR"

# === Test 52: Go-yq transcodes, and its scalars match Python-yq's ===
# The failure this whole change exists for: `apt install yq` / `brew install yq` deliver Go-yq,
# whose bare `yq '.'` prints YAML rather than JSON. The loader must find the -o=json form on its
# own. The `off` assertion is Test 45's, re-run through the other flavor: it is the property
# validate_codex and validate_defaults depend on, and the reason accepting Go-yq is safe.
echo "=== Test 52: the loader works under Go-yq, with Test-45 scalar semantics ==="
TDIR=$(mktemp -d); GODIR=$(mktemp -d); ERR=$(mktemp)
mkyq_go "$GODIR"
sed 's/reasoning_level: extreme.*/reasoning_level: off/' \
    "$FIXTURES/unknown-codex-reasoning.yaml" > "$TDIR/config.yaml"
PATH="$GODIR:$PATH" MESH_CONFIG="$TDIR/config.yaml" XDG_STATE_HOME="$TDIR" "$LOADER" validate 2>"$ERR"; RC=$?
assert_exit "validate exits zero under Go-yq" "0" "$RC"
assert_stderr_contains "warns about the unknown level, as it does under Python-yq" 'unknown value "off"' "$ERR"
VAL=$(PATH="$GODIR:$PATH" MESH_CONFIG="$TDIR/config.yaml" XDG_STATE_HOME="$TDIR" "$LOADER" get-codex 2>/dev/null)
if [ "$VAL" = "gpt-5.5|off" ]; then
    PASS=$((PASS+1)); echo "  PASS: get-codex passes 'off' through as a string under Go-yq"
else
    FAIL=$((FAIL+1)); echo "  FAIL: get-codex printed '$VAL' under Go-yq (expected 'gpt-5.5|off')"
fi
# The same document through both flavors must produce the same snapshot, not merely a valid one.
A=$(MESH_CONFIG="$TDIR/config.yaml" XDG_STATE_HOME="$TDIR" "$LOADER" get-runtime 2>/dev/null)
B=$(PATH="$GODIR:$PATH" MESH_CONFIG="$TDIR/config.yaml" XDG_STATE_HOME="$TDIR" "$LOADER" get-runtime 2>/dev/null)
if [ "$A" = "$B" ]; then
    PASS=$((PASS+1)); echo "  PASS: both flavors yield an identical runtime block"
else
    FAIL=$((FAIL+1)); echo "  FAIL: flavors disagree — python-yq '$A' vs Go-yq '$B'"
fi
rm -rf "$TDIR" "$GODIR" "$ERR"

# The doubles prove the plumbing, not that a REAL Go-yq behaves. When this machine has one —
# even shadowed by a python-yq earlier in PATH, which is the usual arrangement — exercise it.
# When it has none, say so out loud: a silent single-flavor run is exactly what let the Go-yq
# path rot unnoticed in the first place. Hard-requiring both binaries is not an option — there
# is no CI here and the suites are run by hand on whatever machine is at hand.
if REAL_GO="$(find_real_go_yq)"; then
    TDIR=$(mktemp -d); REALDIR=$(mktemp -d); ERR=$(mktemp)
    ln -s "$REAL_GO" "$REALDIR/yq"
    sed 's/reasoning_level: extreme.*/reasoning_level: off/' \
        "$FIXTURES/unknown-codex-reasoning.yaml" > "$TDIR/config.yaml"
    PATH="$REALDIR:$PATH" MESH_CONFIG="$TDIR/config.yaml" XDG_STATE_HOME="$TDIR" "$LOADER" validate 2>"$ERR"; RC=$?
    assert_exit "validate exits zero under the REAL Go-yq on this machine" "0" "$RC"
    VAL=$(PATH="$REALDIR:$PATH" MESH_CONFIG="$TDIR/config.yaml" XDG_STATE_HOME="$TDIR" "$LOADER" get-codex 2>/dev/null)
    if [ "$VAL" = "gpt-5.5|off" ]; then
        PASS=$((PASS+1)); echo "  PASS: real Go-yq ($("$REAL_GO" --version 2>&1|head -1)) keeps 'off' a string"
    else
        FAIL=$((FAIL+1)); echo "  FAIL: real Go-yq printed '$VAL' (expected 'gpt-5.5|off')"
    fi
    rm -rf "$TDIR" "$REALDIR" "$ERR"
else
    echo "  SKIP: no real Go-yq found — the mikefarah path was exercised only against a double"
fi

# === Test 53: a yq that cannot emit JSON is named as the toolchain ===
# Until this split existed, every transcode failure read "check yaml syntax" and sent the
# operator to edit a file nothing had opened. The negative assertion is the point of the test.
echo "=== Test 53: a yq that cannot produce JSON does not get the config blamed for it ==="
TDIR=$(mktemp -d); NJDIR=$(mktemp -d); ERR=$(mktemp)
mkyq_nojson "$NJDIR"
cp "$FIXTURES/valid-minimal.yaml" "$TDIR/config.yaml"
PATH="$NJDIR:$PATH" MESH_CONFIG="$TDIR/config.yaml" XDG_STATE_HOME="$TDIR" "$LOADER" validate 2>"$ERR"; RC=$?
assert_exit "validate exits 1 when yq cannot emit JSON" "1" "$RC"
assert_stderr_contains "names the toolchain" "yq cannot produce JSON" "$ERR"
assert_stderr_lacks "and does NOT accuse a healthy config.yaml" "check yaml syntax" "$ERR"
rm -rf "$TDIR" "$NJDIR" "$ERR"

# === Test 54: a YAML-1.1 resolver is caught where it matters, and only where it matters ===
# Today such a yq surfaces as `codex.reasoning_level: must be a string (got boolean) — quote
# it`, telling the user to fix a value that is already correct. Half (a) is that message being
# replaced by an accurate one. Half (b) is the gate staying per-document: on a config that
# yields no booleans the same binary emitted exactly what a YAML-1.2-core resolver would, and
# the snapshot is all anything downstream reads. Both halves must hold, or a later refactor
# will quietly turn the gate into a blanket probe on every load.
echo "=== Test 54: a YAML-1.1 yq is refused when it can change the config, accepted when it cannot ==="
if ! have_pyyaml; then
    echo "  SKIP: python3 has no PyYAML — the YAML-1.1 double cannot be built"
else
    Y11DIR=$(mktemp -d); mkyq_yaml11 "$Y11DIR"
    TDIR=$(mktemp -d); ERR=$(mktemp)
    cp "$FIXTURES/valid-claude-models-level-off.yaml" "$TDIR/config.yaml"
    PATH="$Y11DIR:$PATH" MESH_CONFIG="$TDIR/config.yaml" XDG_STATE_HOME="$TDIR" "$LOADER" validate 2>"$ERR"; RC=$?
    assert_exit "validate exits 1 under a YAML-1.1 yq" "1" "$RC"
    assert_stderr_contains "names the resolver" "yq mis-resolves YAML scalars" "$ERR"
    assert_stderr_lacks "and does not tell the user to quote a correct value" \
        "must be a string (got boolean)" "$ERR"
    rm -rf "$TDIR" "$ERR"
    TDIR=$(mktemp -d); ERR=$(mktemp)
    cp "$FIXTURES/valid-minimal.yaml" "$TDIR/config.yaml"
    PATH="$Y11DIR:$PATH" MESH_CONFIG="$TDIR/config.yaml" XDG_STATE_HOME="$TDIR" "$LOADER" validate 2>"$ERR"; RC=$?
    assert_exit "…and the same yq is accepted on a config that yields no booleans" "0" "$RC"
    rm -rf "$TDIR" "$ERR" "$Y11DIR"
fi

# === Test 55: a healthy yq plus broken yaml still blames the yaml; empty configs are unchanged ===
# The other half of Test 53's split, and the degenerate case where `jq .` cannot tell the
# flavors apart because both emit the same thing: the verdict must stay the config-level one.
echo "=== Test 55: malformed yaml blames the yaml; empty/comment-only configs unchanged under both flavors ==="
TDIR=$(mktemp -d); ERR=$(mktemp); GODIR=$(mktemp -d)
mkyq_go "$GODIR"
printf 'providers:\n  - id: zai\n    label: "[unclosed\n' > "$TDIR/config.yaml"
MESH_CONFIG="$TDIR/config.yaml" XDG_STATE_HOME="$TDIR" "$LOADER" validate 2>"$ERR"; RC=$?
assert_exit "validate exits 1 on malformed yaml" "1" "$RC"
assert_stderr_contains "blames the yaml" "check yaml syntax" "$ERR"
assert_stderr_lacks "and does not accuse the yq" "yq cannot produce JSON" "$ERR"
for FLAVOR in python-yq go-yq; do
    case "$FLAVOR" in python-yq) PFX="" ;; go-yq) PFX="$GODIR:" ;; esac
    : > "$TDIR/config.yaml"
    PATH="$PFX$PATH" MESH_CONFIG="$TDIR/config.yaml" XDG_STATE_HOME="$TDIR" "$LOADER" validate 2>"$ERR"; RC=$?
    assert_exit "empty config exits 1 ($FLAVOR)" "1" "$RC"
    assert_stderr_contains "…and says providers is empty ($FLAVOR)" \
        "providers: section is empty or missing" "$ERR"
    printf '# only a comment\n' > "$TDIR/config.yaml"
    PATH="$PFX$PATH" MESH_CONFIG="$TDIR/config.yaml" XDG_STATE_HOME="$TDIR" "$LOADER" validate 2>"$ERR"; RC=$?
    assert_exit "comment-only config exits 1 ($FLAVOR)" "1" "$RC"
    assert_stderr_contains "…and says providers is empty ($FLAVOR)" \
        "providers: section is empty or missing" "$ERR"
done
rm -rf "$TDIR" "$ERR" "$GODIR"

# === Test 56: the snapshot never outlives the process, not even when the probe dies ===
# $CONFIG_JSON is config.yaml transcoded — plaintext provider tokens included. Mode 600 decides
# WHO may read it; only the EXIT trap decides HOW LONG it exists. yq_probe can die of its own
# `mktemp -d` with the snapshot already written, so the trap has to be armed before the probe
# can run. It was not: it sat at the end of load_or_die, and this path left the file in TMPDIR.
# The double fails ONLY the probe's mktemp, matched on its template, so the loader's own
# snapshot mktemp still works and the failure lands exactly where the argument says it matters.
echo "=== Test 56: a dying probe does not leave the token-bearing snapshot in TMPDIR ==="
TDIR=$(mktemp -d); ERR=$(mktemp); SHIMDIR=$(mktemp -d); LEAKTMP=$(mktemp -d)
MKTEMP_REAL="$(command -v mktemp)"   # resolved BEFORE the shim is on PATH, or the shim recurses
cat > "$SHIMDIR/mktemp" <<SH
#!/usr/bin/env bash
for a in "\$@"; do case "\$a" in mesh-yqprobe-*) exit 1 ;; esac; done
exec $MKTEMP_REAL "\$@"
SH
chmod +x "$SHIMDIR/mktemp"
cp "$FIXTURES/valid-minimal.yaml" "$TDIR/config.yaml"
# Nothing reads this key. Its only job is to put a BOOLEAN in the snapshot, which is what makes
# the per-document gate run the probe at all — no fixture carries one, by the design's own
# measurement.
printf 'probe_trigger: true\n' >> "$TDIR/config.yaml"
PATH="$SHIMDIR:$PATH" TMPDIR="$LEAKTMP" MESH_CONFIG="$TDIR/config.yaml" XDG_STATE_HOME="$TDIR" "$LOADER" validate 2>"$ERR"; RC=$?
assert_exit "validate exits 1 when the probe's mktemp fails" "1" "$RC"
# Without this the emptiness below would be vacuous — an exit BEFORE the snapshot is written
# also leaves TMPDIR clean, and would pass a test that pins nothing.
assert_stderr_contains "…dying in the probe, with the snapshot already on disk" \
    "mktemp failed for the yq probe" "$ERR"
LEFTOVER="$(ls -A "$LEAKTMP")"
if [ -z "$LEFTOVER" ]; then
    PASS=$((PASS+1)); echo "  PASS: the snapshot is removed even on that death"
else
    FAIL=$((FAIL+1)); echo "  FAIL: the snapshot outlived the process: $LEFTOVER"
fi
rm -rf "$TDIR" "$ERR" "$SHIMDIR" "$LEAKTMP"

# === Test 57: the grok: section ===
# grok: is a GATE like codex:/gemini: — but unlike claude:, its catalog is REQUIRED, because
# the grok reviewer agent refuses to start without a MODEL. A section with no models would
# advertise a reviewer that cannot run.
echo "=== Test 57: grok: section validation ==="
TDIR=$(mktemp -d); ERR=$(mktemp)

cp "$FIXTURES/valid-grok.yaml" "$TDIR/config.yaml"
MESH_CONFIG="$TDIR/config.yaml" XDG_STATE_HOME="$TDIR" "$LOADER" validate 2>"$ERR"; RC=$?
assert_exit "accepts a well-formed grok: section" "0" "$RC"

cp "$FIXTURES/invalid-grok-scalar.yaml" "$TDIR/config.yaml"
MESH_CONFIG="$TDIR/config.yaml" XDG_STATE_HOME="$TDIR" "$LOADER" validate 2>"$ERR"; RC=$?
assert_exit "rejects a scalar grok: section" "1" "$RC"
assert_stderr_contains "explains the mapping requirement" "grok: must be a mapping" "$ERR"
assert_stderr_lacks "no raw jq indexing noise" "Cannot index" "$ERR"

cp "$FIXTURES/invalid-grok-models-missing.yaml" "$TDIR/config.yaml"
MESH_CONFIG="$TDIR/config.yaml" XDG_STATE_HOME="$TDIR" "$LOADER" validate 2>"$ERR"; RC=$?
assert_exit "rejects a grok: section with no catalog" "1" "$RC"
assert_stderr_contains "says the catalog is required" "grok.models: required when grok: section present" "$ERR"

cp "$FIXTURES/invalid-grok-models-empty.yaml" "$TDIR/config.yaml"
MESH_CONFIG="$TDIR/config.yaml" XDG_STATE_HOME="$TDIR" "$LOADER" validate 2>"$ERR"; RC=$?
assert_exit "rejects an empty grok catalog" "1" "$RC"
assert_stderr_contains "says the catalog is required" "grok.models: required when grok: section present" "$ERR"

# The charset is the narrow one. A colon is legal in claude.models and must NOT be here:
# the value becomes a path component and a watch-runs.sh roster entry.
cp "$FIXTURES/invalid-grok-model-charset.yaml" "$TDIR/config.yaml"
MESH_CONFIG="$TDIR/config.yaml" XDG_STATE_HOME="$TDIR" "$LOADER" validate 2>"$ERR"; RC=$?
assert_exit "rejects a colon in a grok model id" "1" "$RC"
assert_stderr_contains "names the narrow charset" "grok.models\[1\]" "$ERR"
assert_stderr_contains "shows which charset applies" "\[A-Za-z0-9._-\]" "$ERR"

{ printf 'providers:\n  - id: zai\n    label: "Z"\n    base_url: https://api.z.ai/api/anthropic\n    token: "tkn"\nmodels:\n  - id: zai/glm\n    label: "GLM"\n    model: glm-5.1\n'
  printf 'grok:\n  models: [grok-4.6, grok-4.6]\n'; } > "$TDIR/config.yaml"
MESH_CONFIG="$TDIR/config.yaml" XDG_STATE_HOME="$TDIR" "$LOADER" validate 2>"$ERR"; RC=$?
assert_exit "rejects a duplicate grok model" "1" "$RC"
assert_stderr_contains "names the duplicate" "duplicate model" "$ERR"
assert_stderr_contains "…and names WHICH id repeats" "grok-4.6" "$ERR"

# Unknown effort passes with a WARN — xAI adds levels without asking this plugin.
cp "$FIXTURES/unknown-grok-effort.yaml" "$TDIR/config.yaml"
MESH_CONFIG="$TDIR/config.yaml" XDG_STATE_HOME="$TDIR" "$LOADER" validate 2>"$ERR"; RC=$?
assert_exit "accepts an unknown reasoning_effort" "0" "$RC"
assert_stderr_contains "warns about it" "unknown value \"ludicrous\"" "$ERR"

# No grok: section at all — every existing config on earth.
cp "$FIXTURES/valid-minimal.yaml" "$TDIR/config.yaml"
MESH_CONFIG="$TDIR/config.yaml" XDG_STATE_HOME="$TDIR" "$LOADER" validate 2>"$ERR"; RC=$?
assert_exit "a config with no grok: section stays valid" "0" "$RC"
GF=$(MESH_CONFIG="$TDIR/config.yaml" XDG_STATE_HOME="$TDIR" "$LOADER" get-flag has_grok 2>/dev/null)
assert_eq_str "has_grok=0 without a section" "0" "$GF"

cp "$FIXTURES/valid-grok.yaml" "$TDIR/config.yaml"
GF=$(MESH_CONFIG="$TDIR/config.yaml" XDG_STATE_HOME="$TDIR" "$LOADER" get-flag has_grok 2>/dev/null)
assert_eq_str "has_grok=1 with a section" "1" "$GF"
LIST=$(MESH_CONFIG="$TDIR/config.yaml" XDG_STATE_HOME="$TDIR" "$LOADER" list-grok-models 2>/dev/null | tr '\n' ' ')
assert_eq_str "list-grok-models emits the catalog in config order" "grok-4.6 grok-4.5 " "$LIST"
EFFORT=$(MESH_CONFIG="$TDIR/config.yaml" XDG_STATE_HOME="$TDIR" "$LOADER" get-grok 2>/dev/null)
assert_eq_str "get-grok returns the effort" "xhigh" "$EFFORT"

# get-grok is a TYPED getter: a malformed section must die here, not return an empty string.
cp "$FIXTURES/broken-grok-valid-codex.yaml" "$TDIR/config.yaml"
MESH_CONFIG="$TDIR/config.yaml" XDG_STATE_HOME="$TDIR" "$LOADER" get-grok >/dev/null 2>"$ERR"; RC=$?
assert_exit "get-grok rejects a malformed catalog" "1" "$RC"
assert_stderr_contains "…and says what the catalog must be" "must be a list of grok model ids" "$ERR"
# …while the codex getter beside it still answers: a broken grok section must not
# ground the other engines (the `ultra` incident, 2026-07-10).
CG=$(MESH_CONFIG="$TDIR/config.yaml" XDG_STATE_HOME="$TDIR" "$LOADER" get-codex 2>/dev/null); RC=$?
assert_exit "get-codex still works with a broken grok section" "0" "$RC"
assert_eq_str "…and returns the codex model" "gpt-5.5|" "$CG"
# has_grok VALIDATES instead of probing (see its case arm), so a MALFORMED section must make
# it EXIT 1 rather than answer 0 or 1. That rc is the contract preflight-env.sh reads to print
# an INVALID row instead of a MISSING one, and it is the whole justification for the flag not
# being a bare `jq -e '.grok'`.
MESH_CONFIG="$TDIR/config.yaml" XDG_STATE_HOME="$TDIR" "$LOADER" get-flag has_grok >/dev/null 2>"$ERR"; RC=$?
assert_exit "has_grok exits 1 on a malformed section" "1" "$RC"

# The same must hold for the PRESET read, which every orchestrator and preflight-env.sh runs
# before anything else. Since Task 3 validate_defaults DOES reach the grok catalog — but only
# when a preset references grok, which this fixture's `builtin: [codex]` deliberately does not.
# So the assertion below pins the UNREFERENCED half of the lazy check, and that half holds: a
# typo in grok.models must not ground the codex and gemini rows of a config that never asked
# for grok.
# The REFERENCED half is covered further down, by broken-grok-referenced.yaml — and the
# CROSS-PRESET half by broken-grok-one-preset.yaml. Both fixtures postdate this comment's
# earlier wording, which described the referenced case as uncovered and recorded what it then
# did: both get-defaults calls exited 1 and preflight-env.sh printed `config INVALID` with
# EVERY row SKIPPED. That is no longer the behaviour — the referenced case now degrades grok
# alone — so read those three blocks together: this one owns the UNREFERENCED half only.
MESH_CONFIG="$TDIR/config.yaml" XDG_STATE_HOME="$TDIR" "$LOADER" get-defaults code_review >/dev/null 2>"$ERR"; RC=$?
assert_exit "get-defaults still answers with a malformed grok section" "0" "$RC"

# The mirror case: a grok: {} section that NO preset references. `validate` must still reject
# it — the full path owns the whole config — while the preset read must not even look.
cp "$FIXTURES/unreferenced-broken-grok.yaml" "$TDIR/config.yaml"
MESH_CONFIG="$TDIR/config.yaml" XDG_STATE_HOME="$TDIR" "$LOADER" validate 2>"$ERR"; RC=$?
assert_exit "validate rejects a catalog-less grok section no preset references" "1" "$RC"

# The REFERENCED case, the other half of the same invariant. `grok` is named by BOTH presets
# while the catalog is broken — config.example.yaml's own shape with one typo. The preset read
# must DEGRADE grok alone and keep answering: a typo in a user-owned file must not ground the
# claude and codex rows of a run that never asked for grok (the `ultra` incident's shape).
# `validate` stays strict on the full path, and has_grok still exits 1 so preflight-env.sh
# prints INVALID on the grok row rather than a MISSING one.
GD_OUT=$(mktemp)
cp "$FIXTURES/broken-grok-referenced.yaml" "$TDIR/config.yaml"
MESH_CONFIG="$TDIR/config.yaml" XDG_STATE_HOME="$TDIR" "$LOADER" get-defaults code_review >"$GD_OUT" 2>"$ERR"; RC=$?
assert_exit "get-defaults answers when a REFERENCED grok catalog is broken" "0" "$RC"
assert_eq_str "…with grok dropped from builtin" "claude codex" "$(jq -r '.builtin | join(" ")' "$GD_OUT" 2>/dev/null)"
assert_eq_str "…grok_models emptied" "0" "$(jq '.grok_models | length' "$GD_OUT" 2>/dev/null)"
assert_eq_str "…the degradation flagged for default mode" "true" "$(jq -r '.grok_degraded' "$GD_OUT" 2>/dev/null)"
assert_eq_str "…and the other engines untouched" "opus fable" "$(jq -r '.claude_models | join(" ")' "$GD_OUT" 2>/dev/null)"
MESH_CONFIG="$TDIR/config.yaml" XDG_STATE_HOME="$TDIR" "$LOADER" get-defaults design_review >"$GD_OUT" 2>"$ERR"; RC=$?
assert_exit "…the second preset degrades the same way" "0" "$RC"
MESH_CONFIG="$TDIR/config.yaml" XDG_STATE_HOME="$TDIR" "$LOADER" validate >/dev/null 2>"$ERR"; RC=$?
assert_exit "validate still rejects a referenced broken catalog" "1" "$RC"
MESH_CONFIG="$TDIR/config.yaml" XDG_STATE_HOME="$TDIR" "$LOADER" get-flag has_grok >/dev/null 2>"$ERR"; RC=$?
assert_exit "has_grok still exits 1 on it, so the grok row reads INVALID" "1" "$RC"

# The same referenced-broken catalog with the preset entry ALSO malformed — the double typo, and
# the half the degrade left behind. Every rule inside the grok_models loop (element type, empty
# value, charset, duplicate) called a bare die, so this shape re-grounded get-defaults for BOTH
# presets and preflight-env.sh then printed CONFIG INVALID with codex, gemini and claude all
# SKIPPED — one line after the WARN above promised "every other engine is unaffected". The
# fixture carries `[zai/glm, zai/glm]`: a slash breaks the charset rule and the repeat breaks the
# duplicate rule, so one file exercises two of the four. The healthy-catalog case below proves
# the rules did not simply go soft.
cp "$FIXTURES/broken-grok-referenced-bad-preset.yaml" "$TDIR/config.yaml"
MESH_CONFIG="$TDIR/config.yaml" XDG_STATE_HOME="$TDIR" "$LOADER" get-defaults code_review >"$GD_OUT" 2>"$ERR"; RC=$?
assert_exit "a broken catalog AND a malformed preset entry still answer" "0" "$RC"
assert_eq_str "…grok dropped, other engines intact" "claude codex" "$(jq -r '.builtin | join(" ")' "$GD_OUT" 2>/dev/null)"
assert_eq_str "…and still flagged degraded" "true" "$(jq -r '.grok_degraded' "$GD_OUT" 2>/dev/null)"
assert_stderr_contains "…the charset rule is REPORTED, not silent" "must start with a letter/digit" "$ERR"
# One report per bad ENTRY PER PRESET, not one per rule. Four is the right number and says so:
# two malformed entries in each of the fixture's two presets, because validate_defaults walks
# the whole defaults: block on every read — the property the WARN text itself names. Six would
# mean the skip after each failed check is gone: grok_preset_die RETURNS when it only warns, so
# without it the second entry is reported by the charset rule AND again by the duplicate rule,
# the first having reached `seen_gm` on its way past.
assert_eq_str "…once per entry per preset, not once per rule" "4" "$(grep -c 'grok_models\[' "$ERR")"
MESH_CONFIG="$TDIR/config.yaml" XDG_STATE_HOME="$TDIR" "$LOADER" validate >/dev/null 2>"$ERR"; RC=$?
assert_exit "…and validate still rejects it" "1" "$RC"

# CONTROL: with a HEALTHY catalog the very same malformed preset entry stays FATAL. Without
# this, deleting the rules outright would satisfy every assertion above.
sed 's/^  models: grok-4.6$/  models: [grok-4.6]/' \
    "$FIXTURES/broken-grok-referenced-bad-preset.yaml" > "$TDIR/config.yaml"
MESH_CONFIG="$TDIR/config.yaml" XDG_STATE_HOME="$TDIR" "$LOADER" get-defaults code_review >/dev/null 2>"$ERR"; RC=$?
assert_exit "a healthy catalog keeps the preset rules fatal" "1" "$RC"

# A scalar `grok:` section — the same invariant, one KIND of breakage over. `grok: false` is
# how a user tries to switch a section off without deleting it, and the type gate used to die
# on the preset path, so preflight printed CONFIG INVALID and SKIPPED every row: codex and
# gemini taken down by a grok typo, which is the `ultra` incident's shape and the one thing
# `preflight-env.sh` forbids in so many words. It now degrades exactly as a broken catalog
# does. `validate` stays strict, and no raw jq noise may reach stderr — the reason the gate
# was unconditional in the first place is that `(.grok.models // [])[]` cannot index a boolean.
cp "$FIXTURES/scalar-grok-referenced.yaml" "$TDIR/config.yaml"
MESH_CONFIG="$TDIR/config.yaml" XDG_STATE_HOME="$TDIR" "$LOADER" get-defaults code_review >"$GD_OUT" 2>"$ERR"; RC=$?
assert_exit "get-defaults answers on a SCALAR grok section a preset references" "0" "$RC"
assert_eq_str "…with grok dropped from builtin" "claude codex" "$(jq -r '.builtin | join(" ")' "$GD_OUT" 2>/dev/null)"
assert_eq_str "…grok_models emptied" "0" "$(jq '.grok_models | length' "$GD_OUT" 2>/dev/null)"
assert_eq_str "…and flagged degraded for default mode" "true" "$(jq -r '.grok_degraded' "$GD_OUT" 2>/dev/null)"
assert_eq_str "…the other engines untouched" "opus fable" "$(jq -r '.claude_models | join(" ")' "$GD_OUT" 2>/dev/null)"
assert_stderr_lacks "no raw jq noise on the preset path" "Cannot index" "$ERR"
MESH_CONFIG="$TDIR/config.yaml" XDG_STATE_HOME="$TDIR" "$LOADER" get-defaults design_review >"$GD_OUT" 2>"$ERR"; RC=$?
assert_exit "…the preset that never names grok answers too" "0" "$RC"
assert_eq_str "…and is NOT flagged degraded" "false" "$(jq -r '.grok_degraded' "$GD_OUT" 2>/dev/null)"
MESH_CONFIG="$TDIR/config.yaml" XDG_STATE_HOME="$TDIR" "$LOADER" validate >/dev/null 2>"$ERR"; RC=$?
assert_exit "validate still rejects a scalar grok section" "1" "$RC"
assert_stderr_contains "…naming the type it got" "must be a mapping" "$ERR"
MESH_CONFIG="$TDIR/config.yaml" XDG_STATE_HOME="$TDIR" "$LOADER" get-flag has_grok >/dev/null 2>"$ERR"; RC=$?
assert_exit "has_grok still exits 1 on it" "1" "$RC"
# The CROSS-PRESET case, the third shape of the same invariant. GROK_CATALOG_BROKEN is ONE
# variable for the whole run while validate_defaults iterates BOTH presets, so a catalog broken
# for design_review must not be reported to code_review, which never named grok. The two
# fixtures above cannot catch this: one has grok in NEITHER preset, the other in BOTH.
cp "$FIXTURES/broken-grok-one-preset.yaml" "$TDIR/config.yaml"
MESH_CONFIG="$TDIR/config.yaml" XDG_STATE_HOME="$TDIR" "$LOADER" get-defaults code_review >"$GD_OUT" 2>"$ERR"; RC=$?
assert_exit "get-defaults answers for the preset that never names grok" "0" "$RC"
assert_eq_str "…and does NOT flag that preset degraded" "false" "$(jq -r '.grok_degraded' "$GD_OUT" 2>/dev/null)"
assert_eq_str "…its builtin is untouched" "claude codex" "$(jq -r '.builtin | join(" ")' "$GD_OUT" 2>/dev/null)"
MESH_CONFIG="$TDIR/config.yaml" XDG_STATE_HOME="$TDIR" "$LOADER" get-defaults design_review >"$GD_OUT" 2>"$ERR"; RC=$?
assert_exit "…while the preset that DOES name grok still answers" "0" "$RC"
assert_eq_str "…and that one IS flagged degraded" "true" "$(jq -r '.grok_degraded' "$GD_OUT" 2>/dev/null)"
assert_eq_str "…with grok dropped from its builtin" "claude" "$(jq -r '.builtin | join(" ")' "$GD_OUT" 2>/dev/null)"
# The UNREFERENCED fixture must not be flagged: nothing read its catalog, so nothing degraded.
cp "$FIXTURES/broken-grok-valid-codex.yaml" "$TDIR/config.yaml"
MESH_CONFIG="$TDIR/config.yaml" XDG_STATE_HOME="$TDIR" "$LOADER" get-defaults code_review >"$GD_OUT" 2>"$ERR"
assert_eq_str "grok_degraded is false when no preset references grok" "false" "$(jq -r '.grok_degraded' "$GD_OUT" 2>/dev/null)"
rm -f "$GD_OUT"
MESH_CONFIG="$TDIR/config.yaml" XDG_STATE_HOME="$TDIR" "$LOADER" get-defaults code_review >/dev/null 2>"$ERR"; RC=$?
assert_exit "get-defaults ignores a grok section no preset references" "0" "$RC"

rm -rf "$TDIR" "$ERR"

# === Test 58: defaults.<preset> grok gating ===
# Two rules, and they point in OPPOSITE directions. grok_models without grok in builtin is the
# same fail-closed rule claude_models has. grok in builtin WITHOUT grok_models is also an
# error — the mirror image, and unlike claude there is no single-reviewer fallback to land on,
# because the reviewer agent stops without a MODEL.
echo "=== Test 58: defaults grok gating ==="
TDIR=$(mktemp -d); ERR=$(mktemp)
BASE=$(printf 'providers:\n  - id: zai\n    label: "Z"\n    base_url: https://api.z.ai/api/anthropic\n    token: "tkn"\nmodels:\n  - id: zai/glm\n    label: "GLM"\n    model: glm-5.1\n')
GCAT=$(printf 'grok:\n  models: [grok-4.6, grok-4.5]\n')

cp "$FIXTURES/invalid-defaults-builtin-grok-no-section.yaml" "$TDIR/config.yaml"
MESH_CONFIG="$TDIR/config.yaml" XDG_STATE_HOME="$TDIR" "$LOADER" validate 2>"$ERR"; RC=$?
assert_exit "rejects builtin grok with no grok: section" "1" "$RC"
assert_stderr_contains "says which section is missing" 'builtin lists "grok" but no grok: section' "$ERR"

{ printf '%s\n' "$BASE"; printf '%s\n' "$GCAT"; printf 'defaults:\n  code_review:\n    builtin: [grok]\n'; } > "$TDIR/config.yaml"
MESH_CONFIG="$TDIR/config.yaml" XDG_STATE_HOME="$TDIR" "$LOADER" validate 2>"$ERR"; RC=$?
assert_exit "rejects builtin grok with no grok_models" "1" "$RC"
assert_stderr_contains "explains the reviewer needs a model" "grok_models is empty" "$ERR"

{ printf '%s\n' "$BASE"; printf '%s\n' "$GCAT"; printf 'defaults:\n  code_review:\n    builtin: [claude]\n    grok_models: [grok-4.6]\n'; } > "$TDIR/config.yaml"
MESH_CONFIG="$TDIR/config.yaml" XDG_STATE_HOME="$TDIR" "$LOADER" validate 2>"$ERR"; RC=$?
assert_exit "rejects grok_models without grok in builtin" "1" "$RC"
assert_stderr_contains "names the missing builtin entry" 'missing from defaults.code_review.builtin' "$ERR"

{ printf '%s\n' "$BASE"; printf '%s\n' "$GCAT"; printf 'defaults:\n  code_review:\n    builtin: [grok]\n    grok_models: [grok-4.7]\n'; } > "$TDIR/config.yaml"
MESH_CONFIG="$TDIR/config.yaml" XDG_STATE_HOME="$TDIR" "$LOADER" validate 2>"$ERR"; RC=$?
assert_exit "rejects a grok_models entry outside the catalog" "1" "$RC"
assert_stderr_contains "points at the catalog" "grok.models catalog" "$ERR"

# Charset gate, the twin of the claude_models case above (Test 47's block): membership is a
# substring match against the space-joined catalog, so a multi-token value whose words are
# ADJACENT catalog members would SPAN it. A missing comma in `["grok-4.6 grok-4.5"]` is ONE
# YAML string, and against the catalog "grok-4.6 grok-4.5 " it would match and validate clean,
# handing the orchestrator one bogus model name. GROK_IDENT_RE forbids the space, so the entry
# is reported for what it is — and this assertion is what makes the SYNC marker's claim true
# on the grok side: delete the charset line and the suite goes red here.
{ printf '%s\n' "$BASE"; printf '%s\n' "$GCAT"; printf 'defaults:\n  code_review:\n    builtin: [grok]\n    grok_models: ["grok-4.6 grok-4.5"]\n'; } > "$TDIR/config.yaml"
MESH_CONFIG="$TDIR/config.yaml" XDG_STATE_HOME="$TDIR" "$LOADER" validate 2>"$ERR"; RC=$?
assert_exit "rejects a space-spanning grok_models entry (missing comma)" "1" "$RC"
assert_stderr_contains "reports it as a charset violation, not as unknown" 'must start with a letter/digit' "$ERR"

{ printf '%s\n' "$BASE"; printf '%s\n' "$GCAT"; printf 'defaults:\n  code_review:\n    builtin: [grok]\n    grok_models: [grok-4.6, grok-4.6]\n'; } > "$TDIR/config.yaml"
MESH_CONFIG="$TDIR/config.yaml" XDG_STATE_HOME="$TDIR" "$LOADER" validate 2>"$ERR"; RC=$?
assert_exit "rejects a duplicate grok_models entry" "1" "$RC"

{ printf '%s\n' "$BASE"; printf '%s\n' "$GCAT"; printf 'defaults:\n  design_review:\n    builtin: [grok]\n    grok_models: [grok-4.5]\n'; } > "$TDIR/config.yaml"
MESH_CONFIG="$TDIR/config.yaml" XDG_STATE_HOME="$TDIR" "$LOADER" validate 2>"$ERR"; RC=$?
assert_exit "accepts a well-formed design_review preset" "0" "$RC"
DJ=$(MESH_CONFIG="$TDIR/config.yaml" XDG_STATE_HOME="$TDIR" "$LOADER" get-defaults design_review 2>/dev/null)
GM=$(printf '%s' "$DJ" | jq -r '.grok_models | join(",")')
assert_eq_str "get-defaults carries grok_models" "grok-4.5" "$GM"

# A preset with no grok at all still emits an ARRAY, never null — both orchestrators iterate it.
{ printf '%s\n' "$BASE"; printf 'defaults:\n  code_review:\n    builtin: [claude]\n'; } > "$TDIR/config.yaml"
DJ=$(MESH_CONFIG="$TDIR/config.yaml" XDG_STATE_HOME="$TDIR" "$LOADER" get-defaults code_review 2>/dev/null)
GT=$(printf '%s' "$DJ" | jq -r '.grok_models | type')
assert_eq_str "grok_models defaults to an array" "array" "$GT"

rm -rf "$TDIR" "$ERR"

# === Test 59: the claude catalog's error text is frozen ===
# validate_claude no longer owns its per-element loop — validate_model_catalog does, and grok:
# calls the same helper. Every message that loop emits is a contract users read and this suite
# asserts, so the refactor was checked once by hand against text captured beforehand. That check
# lived in a temp file and died with the session. Nothing else here would catch a message MOVING:
# the assertions above (Test 47) grep for substrings, so text that had quietly grown a
# grok-flavoured clause, lost its index, or swapped its example would still pass every one.
#
# The golden file is the whole nine-case stderr, byte for byte. Seven cases produce a message:
# the non-mapping section, the scalar .models value (the only list-level failure, so the only
# one with no index), and the four per-element guards — element type, empty value, charset,
# duplicate — with the charset one covered twice, by a leading dash and by an embedded space.
# The other two print NOTHING and are recorded as a header with no body under it: an empty list
# and a mapping with no .models key are both legal "no catalog". That silence is as much of a
# contract as the text, and it is what breaks the day someone "fixes" an empty catalog into an
# error — a golden file that only collected messages would not have noticed.
echo "=== Test 59: claude catalog messages match the golden file byte for byte ==="
TDIR=$(mktemp -d); ACTUAL=$(mktemp)
BASE=$(printf 'providers:\n  - id: zai\n    label: "Z"\n    base_url: https://api.z.ai/api/anthropic\n    token: "tkn"\nmodels:\n  - id: zai/glm\n    label: "GLM"\n    model: glm-5.1\n')
for CASE in 'claude:\n  models: opus\n' \
            'claude:\n  models:\n    - 5\n' \
            'claude:\n  models:\n    - "-opus"\n' \
            'claude:\n  models: [opus, "claude fable"]\n' \
            'claude:\n  models: [opus, fable, opus]\n' \
            'claude:\n  models: [opus, ""]\n' \
            'claude:\n  models: []\n' \
            'claude:\n  other_key: x\n' \
            'claude: false\n'; do
    { printf '%s\n' "$BASE"; printf "$CASE"; } > "$TDIR/config.yaml"
    printf -- '--- case: %s\n' "$CASE" >> "$ACTUAL"
    MESH_CONFIG="$TDIR/config.yaml" XDG_STATE_HOME="$TDIR" "$LOADER" validate 2>> "$ACTUAL"
done
# "the two blobs differ" is not actionable — print the diff, or the next maintainer has to
# reconstruct the nine cases by hand before they can see WHICH message moved.
if diff -u "$FIXTURES/golden-claude-catalog-messages.txt" "$ACTUAL" > "$TDIR/catalog.diff" 2>&1; then
    PASS=$((PASS+1)); echo "  PASS: every claude.models message is byte-for-byte unchanged"
else
    FAIL=$((FAIL+1)); echo "  FAIL: a claude.models message moved (-golden / +actual):"
    sed 's/^/    /' "$TDIR/catalog.diff"
fi
rm -rf "$TDIR" "$ACTUAL"

# === Test 60: grok.model_efforts — per-model reasoning effort ===
# `reasoning_effort` is ONE value for the whole section, but the CLI validates --effort PER
# MODEL and rejects a bad pair at argument parsing (rc=1), before any API call. Measured
# 2026-08-30 against grok 1.0.5: grok-4.6 accepts xhigh|high|medium|low, grok-4.5 only
# high|medium|low, and most proxied entries all five. A catalog of more than one model
# therefore cannot be served by a single level, and `model_efforts` overrides the section
# default per model.
#
# It is validated exactly where `reasoning_effort` is — inside validate_grok, so `validate`,
# `get-grok`, preflight's grok row AND `has_grok` see it (has_grok runs validate_grok), while
# `list-grok-models` alone does not. Deliberate, not a weaker gate: a new key does not invent a
# stricter path than the key it sits beside, and that laziness is what keeps a broken grok
# section from grounding a codex-only review.
echo "=== Test 60: grok.model_efforts ==="
TDIR=$(mktemp -d); ERR=$(mktemp)
ME_BASE='providers:\n  - id: zai\n    label: "Z"\n    base_url: https://api.z.ai/api/anthropic\n    token: "tkn"\nmodels:\n  - id: zai/glm\n    label: "GLM"\n    model: glm-5.1\n'

cp "$FIXTURES/valid-grok-model-efforts.yaml" "$TDIR/config.yaml"
MESH_CONFIG="$TDIR/config.yaml" XDG_STATE_HOME="$TDIR" "$LOADER" validate 2>"$ERR"; RC=$?
assert_exit "accepts a well-formed model_efforts table" "0" "$RC"
assert_stderr_lacks "…silently, its levels being known ones" "unknown value" "$ERR"

assert_eq_str "get-grok <model> reads the table" \
    "xhigh" "$(MESH_CONFIG="$TDIR/config.yaml" XDG_STATE_HOME="$TDIR" "$LOADER" get-grok grok-4.6 2>/dev/null)"
assert_eq_str "…per model, not one value handed to every model" \
    "high" "$(MESH_CONFIG="$TDIR/config.yaml" XDG_STATE_HOME="$TDIR" "$LOADER" get-grok grok-4.5 2>/dev/null)"
assert_eq_str "a model absent from the table falls back to the section default" \
    "max" "$(MESH_CONFIG="$TDIR/config.yaml" XDG_STATE_HOME="$TDIR" "$LOADER" get-grok dks-ultra 2>/dev/null)"
# The no-argument contract must not move: grok-exec passes "$MODEL", which is legitimately
# empty on a direct call that names no model, and that call has to behave as it did before
# this key existed.
assert_eq_str "get-grok with no argument still prints the section default" \
    "max" "$(MESH_CONFIG="$TDIR/config.yaml" XDG_STATE_HOME="$TDIR" "$LOADER" get-grok 2>/dev/null)"
assert_eq_str "…and an empty argument is that same case, not a lookup of the empty id" \
    "max" "$(MESH_CONFIG="$TDIR/config.yaml" XDG_STATE_HOME="$TDIR" "$LOADER" get-grok "" 2>/dev/null)"

# A section carrying no table at all: the argument is accepted and changes nothing.
cp "$FIXTURES/valid-grok.yaml" "$TDIR/config.yaml"
assert_eq_str "get-grok <model> falls back when the section has no table" \
    "xhigh" "$(MESH_CONFIG="$TDIR/config.yaml" XDG_STATE_HOME="$TDIR" "$LOADER" get-grok grok-4.5 2>/dev/null)"

# An entry for a model outside the catalog is a HARD error, the twin of the rule that every
# defaults.<preset>.grok_models entry must be a catalog member. A silent no-op is the failure
# this key exists to prevent: the user believes that model runs at the level they wrote.
{ printf '%b' "$ME_BASE"; printf 'grok:\n  models: [grok-4.6]\n  model_efforts:\n    grok-4.7: max\n'; } > "$TDIR/config.yaml"
MESH_CONFIG="$TDIR/config.yaml" XDG_STATE_HOME="$TDIR" "$LOADER" validate 2>"$ERR"; RC=$?
assert_exit "rejects an entry for a model outside the catalog" "1" "$RC"
assert_stderr_contains "names the offending key" "grok-4.7" "$ERR"
assert_stderr_contains "…and says which list it must belong to" "grok.models" "$ERR"
# `has_grok` is consumed as "can a grok reviewer be dispatched" — its own comment says so — and
# a broken table makes dispatch impossible, so the flag has to see it. It used to answer 1 here,
# and this suite pinned that as the contract: the orchestrator then offered grok, dispatched it,
# and the reviewer died on `get-grok "$MODEL"` AFTER its run dir existed, which the guard reads
# as STALLED — "killed mid-flight" — and STALLED means re-dispatch, so a max_redispatch round
# went on an error no retry can fix. Found independently by all three reviewers of this branch.
#
# This is NOT the `ultra` incident returning. That was about a broken grok section GROUNDING the
# environment; here rc=1 is what both orchestrators already handle by degrading grok ALONE and
# printing the validator's message (mesh-review/commands/mesh-review.md Step 1), and what makes preflight
# print INVALID on the grok row rather than MISSING. The unconditional type gate at the top of
# validate_defaults is untouched, so an UNREFERENCED broken section still grounds nothing.
MESH_CONFIG="$TDIR/config.yaml" XDG_STATE_HOME="$TDIR" "$LOADER" get-flag has_grok >/dev/null 2>"$ERR"; RC=$?
assert_exit "has_grok exits 1 on a broken model_efforts table" "1" "$RC"
assert_stderr_contains "…with the validator's own message" "not in grok.models" "$ERR"
MESH_CONFIG="$TDIR/config.yaml" XDG_STATE_HOME="$TDIR" "$LOADER" get-grok grok-4.6 >/dev/null 2>"$ERR"; RC=$?
assert_exit "get-grok fails on it too, so a direct grok-exec call STOPs" "1" "$RC"

# A preset that REFERENCES grok with a broken table must degrade grok alone and say so — the
# same shape a broken catalog already gets, so `default` mode announces the missing reviewer
# instead of dispatching one that cannot start. The other engines are untouched.
{ printf '%b' "$ME_BASE"
  printf 'grok:\n  models: [grok-4.6]\n  model_efforts:\n    grok-4.7: max\n'
  printf 'defaults:\n  code_review:\n    builtin: [claude, grok]\n    grok_models: [grok-4.6]\n'; } > "$TDIR/config.yaml"
MESH_CONFIG="$TDIR/config.yaml" XDG_STATE_HOME="$TDIR" "$LOADER" get-defaults code_review >"$TDIR/gd.json" 2>"$ERR"; RC=$?
assert_exit "get-defaults still answers when a preset names grok and the table is broken" "0" "$RC"
assert_eq_str "…flagged degraded" "true" "$(jq -r '.grok_degraded' "$TDIR/gd.json" 2>/dev/null)"
assert_eq_str "…grok dropped from builtin" "claude" "$(jq -r '.builtin | join(" ")' "$TDIR/gd.json" 2>/dev/null)"
assert_eq_str "…and its model list emptied" "0" "$(jq '.grok_models | length' "$TDIR/gd.json" 2>/dev/null)"
rm -f "$TDIR/gd.json"

{ printf '%b' "$ME_BASE"; printf 'grok:\n  models: [grok-4.6]\n  model_efforts: [xhigh]\n'; } > "$TDIR/config.yaml"
MESH_CONFIG="$TDIR/config.yaml" XDG_STATE_HOME="$TDIR" "$LOADER" validate 2>"$ERR"; RC=$?
assert_exit "rejects a model_efforts that is not a mapping" "1" "$RC"
assert_stderr_contains "explains the mapping requirement" "grok.model_efforts: must be a mapping" "$ERR"
assert_stderr_lacks "no raw jq indexing noise" "Cannot index" "$ERR"

{ printf '%b' "$ME_BASE"; printf 'grok:\n  models: [grok-4.6]\n  model_efforts:\n    grok-4.6: 3\n'; } > "$TDIR/config.yaml"
MESH_CONFIG="$TDIR/config.yaml" XDG_STATE_HOME="$TDIR" "$LOADER" validate 2>"$ERR"; RC=$?
assert_exit "rejects a non-string effort value" "1" "$RC"
assert_stderr_contains "names the model whose value is wrong" "grok-4.6" "$ERR"
assert_stderr_contains "…and the type it got" "got number" "$ERR"

# Unknown levels WARN and pass, exactly as reasoning_effort does — xAI adds levels with new
# models and the CLI is the final validator. Never an enum.
{ printf '%b' "$ME_BASE"; printf 'grok:\n  models: [grok-4.6]\n  model_efforts:\n    grok-4.6: "ludicrous"\n'; } > "$TDIR/config.yaml"
MESH_CONFIG="$TDIR/config.yaml" XDG_STATE_HOME="$TDIR" "$LOADER" validate 2>"$ERR"; RC=$?
assert_exit "accepts an unknown per-model level" "0" "$RC"
assert_stderr_contains "…warning about it and naming the model" "grok.model_efforts" "$ERR"
assert_stderr_contains "…and quoting the value" "ludicrous" "$ERR"
assert_eq_str "…and passes it through to the CLI" \
    "ludicrous" "$(MESH_CONFIG="$TDIR/config.yaml" XDG_STATE_HOME="$TDIR" "$LOADER" get-grok grok-4.6 2>/dev/null)"

# An empty value means "unset", the reasoning_effort semantics: a user who comments a level out
# and leaves the key behind means "let the section default decide", not "pass --effort ''".
{ printf '%b' "$ME_BASE"; printf 'grok:\n  models: [grok-4.6]\n  reasoning_effort: high\n  model_efforts:\n    grok-4.6: ""\n'; } > "$TDIR/config.yaml"
MESH_CONFIG="$TDIR/config.yaml" XDG_STATE_HOME="$TDIR" "$LOADER" validate 2>"$ERR"; RC=$?
assert_exit "accepts an empty per-model value" "0" "$RC"
assert_eq_str "…and treats it as unset, falling back to the section default" \
    "high" "$(MESH_CONFIG="$TDIR/config.yaml" XDG_STATE_HOME="$TDIR" "$LOADER" get-grok grok-4.6 2>/dev/null)"

# The table alone, with no section default: a model outside it resolves to nothing at all, and
# grok-exec then passes no --effort and lets ~/.grok/config.toml decide.
{ printf '%b' "$ME_BASE"; printf 'grok:\n  models: [grok-4.6, grok-4.5]\n  model_efforts:\n    grok-4.6: xhigh\n'; } > "$TDIR/config.yaml"
assert_eq_str "the table works without a section default" \
    "xhigh" "$(MESH_CONFIG="$TDIR/config.yaml" XDG_STATE_HOME="$TDIR" "$LOADER" get-grok grok-4.6 2>/dev/null)"
assert_eq_str "…and an unlisted model resolves to nothing, so no --effort is passed" \
    "" "$(MESH_CONFIG="$TDIR/config.yaml" XDG_STATE_HOME="$TDIR" "$LOADER" get-grok grok-4.5 2>/dev/null)"

rm -rf "$TDIR" "$ERR"

# === Test 61: a broken grok catalog must not let a PRESET error ground the environment ===
# The two fail-closed preset rules — grok in builtin without grok_models, and grok_models
# without grok in builtin — exist to stop the orchestrator dispatching a reviewer the agent
# refuses to start for want of a MODEL. When the catalog itself does not validate, grok is
# dropped from the read anyway, so those rules guard a dispatch that cannot happen while their
# `die` grounds codex, gemini and claude — one line after the WARN has promised the opposite.
# Both shapes measured 2026-08-30; both answered WARN-then-die before the gate.
echo "=== Test 61: broken grok catalog + a preset error degrades, never grounds ==="
for FX in broken-grok-preset-no-models broken-grok-preset-orphan-models; do
    TDIR=$(mktemp -d); ERR=$(mktemp); GD_OUT=$(mktemp)
    cp "$FIXTURES/$FX.yaml" "$TDIR/config.yaml"
    MESH_CONFIG="$TDIR/config.yaml" XDG_STATE_HOME="$TDIR" "$LOADER" get-defaults code_review >"$GD_OUT" 2>"$ERR"; RC=$?
    assert_exit "$FX: get-defaults answers instead of dying" "0" "$RC"
    assert_eq_str "$FX: codex survives" "codex" "$(jq -r '.builtin | join(" ")' "$GD_OUT" 2>/dev/null)"
    assert_eq_str "$FX: degradation flagged" "true" "$(jq -r '.grok_degraded' "$GD_OUT" 2>/dev/null)"
    # The invariant the whole suppression rests on: while degraded, grok is never dispatchable.
    # If either of these ever fails, the fail-closed rules must come back — a preset carrying
    # grok with no model would then reach an orchestrator.
    assert_eq_str "$FX: grok never left in builtin while degraded" "0" \
        "$(jq '[.builtin[] | select(. == "grok")] | length' "$GD_OUT" 2>/dev/null)"
    assert_eq_str "$FX: grok_models emptied while degraded" "0" "$(jq '.grok_models | length' "$GD_OUT" 2>/dev/null)"
    # Reported, not silenced: the preset error still reaches the user, as a WARN.
    assert_stderr_contains "$FX: the preset error is still reported" "NOT fatal for that preset" "$ERR"
    # And the strict path is untouched — validate_grok runs before validate_defaults in
    # validate_all and dies there, so the gate above is unreachable from `validate`.
    MESH_CONFIG="$TDIR/config.yaml" XDG_STATE_HOME="$TDIR" "$LOADER" validate >/dev/null 2>"$ERR"; RC=$?
    assert_exit "$FX: validate still rejects the file" "1" "$RC"
    rm -f "$ERR" "$GD_OUT"; rm -rf "$TDIR"
done

# A HEALTHY catalog must still make both preset rules fatal — the gate keys on the broken
# catalog, never on the preset error itself.
echo "=== Test 62: with a valid catalog both preset rules stay fatal ==="
for PAIR in "builtin: [codex, grok]|grok_models is empty" "builtin: [codex]
    grok_models: [grok-4.6]|is missing from"; do
    PRESET="${PAIR%%|*}"; NEEDLE="${PAIR##*|}"
    TDIR=$(mktemp -d); ERR=$(mktemp)
    { printf 'providers:\n  - id: zai\n    label: "Z"\n    base_url: https://api.z.ai/api/anthropic\n    token: "tkn"\n'
      printf 'models:\n  - id: zai/glm\n    label: "GLM"\n    model: glm-5.1\n'
      printf 'codex:\n  model: gpt-5.5\n'
      printf 'grok:\n  models: [grok-4.6]\n'
      printf 'defaults:\n  code_review:\n    %s\n' "$PRESET"; } > "$TDIR/config.yaml"
    MESH_CONFIG="$TDIR/config.yaml" XDG_STATE_HOME="$TDIR" "$LOADER" get-defaults code_review >/dev/null 2>"$ERR"; RC=$?
    assert_exit "valid catalog: the preset error is still fatal" "1" "$RC"
    assert_stderr_contains "…and says which rule" "$NEEDLE" "$ERR"
    rm -f "$ERR"; rm -rf "$TDIR"
done

# === native builtin and native_models ===
# $BASE is the Test 50 providers+models snippet; redefine it here so this block
# does not depend on a later test leaving it in scope.
BASE=$(printf 'providers:\n  - id: zai\n    label: "Z"\n    base_url: https://api.z.ai/api/anthropic\n    token: "tkn"\nmodels:\n  - id: zai/glm\n    label: "GLM"\n    model: glm-5.1\n')

echo "=== Test: native is a valid builtin ==="
TDIR=$(mktemp -d)
printf '%s\n' "$BASE" > "$TDIR/config.yaml"
printf 'defaults:\n  code_review:\n    builtin: [native]\n' >> "$TDIR/config.yaml"
ERR=$(mktemp)
MESH_CONFIG="$TDIR/config.yaml" XDG_STATE_HOME="$TDIR" "$LOADER" validate 2>"$ERR"
RC=$?
assert_exit "accepts builtin native with no native_models" "0" "$RC"
rm -rf "$TDIR" "$ERR"

echo "=== Test: native_models without native in builtin is invalid ==="
TDIR=$(mktemp -d)
cp "$FIXTURES/invalid-defaults-native-models-no-native.yaml" "$TDIR/config.yaml"
ERR=$(mktemp)
MESH_CONFIG="$TDIR/config.yaml" XDG_STATE_HOME="$TDIR" "$LOADER" validate 2>"$ERR"
RC=$?
assert_exit "rejects native_models without native" "1" "$RC"
assert_stderr_contains "names the missing builtin entry" 'is missing from defaults.code_review.builtin' "$ERR"
rm -rf "$TDIR" "$ERR"

echo "=== Test: native_models charset rejects a slash ==="
TDIR=$(mktemp -d)
cp "$FIXTURES/invalid-defaults-native-models-charset.yaml" "$TDIR/config.yaml"
ERR=$(mktemp)
MESH_CONFIG="$TDIR/config.yaml" XDG_STATE_HOME="$TDIR" "$LOADER" validate 2>"$ERR"
RC=$?
assert_exit "rejects slashed native_models entry" "1" "$RC"
assert_stderr_contains "names the charset" '[A-Za-z0-9._-]' "$ERR"
rm -rf "$TDIR" "$ERR"

echo "=== Test: native_models charset rejects @ ==="
TDIR=$(mktemp -d)
printf '%s\n' "$BASE" > "$TDIR/config.yaml"
printf 'defaults:\n  code_review:\n    builtin: [native]\n    native_models: ["opus@bedrock"]\n' >> "$TDIR/config.yaml"
ERR=$(mktemp)
MESH_CONFIG="$TDIR/config.yaml" XDG_STATE_HOME="$TDIR" "$LOADER" validate 2>"$ERR"
RC=$?
assert_exit "rejects @ in native_models" "1" "$RC"
rm -rf "$TDIR" "$ERR"

echo "=== Test: native does not satisfy claude_models pairing ==="
TDIR=$(mktemp -d)
printf '%s\n' "$BASE" > "$TDIR/config.yaml"
printf 'claude:\n  models: [opus]\n' >> "$TDIR/config.yaml"
printf 'defaults:\n  code_review:\n    builtin: [native]\n    claude_models: [opus]\n' >> "$TDIR/config.yaml"
ERR=$(mktemp)
MESH_CONFIG="$TDIR/config.yaml" XDG_STATE_HOME="$TDIR" "$LOADER" validate 2>"$ERR"
RC=$?
assert_exit "native does not stand in for claude in claude_models pairing" "1" "$RC"
assert_stderr_contains "still wants claude in builtin" '"claude" is missing from defaults.code_review.builtin' "$ERR"
rm -rf "$TDIR" "$ERR"

echo "=== Test: get-defaults emits native_models ==="
TDIR=$(mktemp -d)
printf '%s\n' "$BASE" > "$TDIR/config.yaml"
printf 'defaults:\n  code_review:\n    builtin: [native]\n    native_models: [grok-4.6, glm-5-3]\n' >> "$TDIR/config.yaml"
GOT=$(MESH_CONFIG="$TDIR/config.yaml" XDG_STATE_HOME="$TDIR" "$LOADER" get-defaults code_review | jq -r '.native_models | join(",")')
assert_eq_str "native_models list" "grok-4.6,glm-5-3" "$GOT"
printf '%s\n' "$BASE" > "$TDIR/config.yaml"
printf 'defaults:\n  code_review:\n    builtin: [claude]\n' >> "$TDIR/config.yaml"
GOT=$(MESH_CONFIG="$TDIR/config.yaml" XDG_STATE_HOME="$TDIR" "$LOADER" get-defaults code_review | jq -r 'has("native_models")')
assert_eq_str "native_models key always present" "true" "$GOT"
GOT=$(MESH_CONFIG="$TDIR/config.yaml" XDG_STATE_HOME="$TDIR" "$LOADER" get-defaults code_review | jq -r '.native_models | type')
assert_eq_str "absent native_models becomes []" "array" "$GOT"
rm -rf "$TDIR"

echo "=== Test: 0.12.0 preset without native still validates ==="
TDIR=$(mktemp -d)
printf '%s\n' "$BASE" > "$TDIR/config.yaml"
printf 'claude:\n  models: [opus]\ncodex:\n  model: gpt-5.5\n' >> "$TDIR/config.yaml"
printf 'defaults:\n  code_review:\n    builtin: [claude, codex]\n    claude_models: [opus]\n' >> "$TDIR/config.yaml"
ERR=$(mktemp)
MESH_CONFIG="$TDIR/config.yaml" XDG_STATE_HOME="$TDIR" "$LOADER" validate 2>"$ERR"
RC=$?
assert_exit "old preset without native stays valid" "0" "$RC"
rm -rf "$TDIR" "$ERR"

echo ""
echo "=== Summary: $PASS passed, $FAIL failed ==="
[ "$FAIL" = "0" ]
