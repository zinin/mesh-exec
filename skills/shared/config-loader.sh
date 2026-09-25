#!/usr/bin/env bash
# config-loader.sh — parses, validates, and exports the mesh config (mesh-exec, mesh-review).
#
# Usage:
#   config-loader.sh validate           # validate only, exit 0/1
#   config-loader.sh config-path        # print the config file path (no validation; works pre-config)
#   config-loader.sh data-dir           # print the state dir holding runs/ and state/ (no validation)
#   config-loader.sh export <model-id>  # validate + print `export KEY=val` lines
#
# Config: $MESH_CONFIG, else ${XDG_CONFIG_HOME:-~/.config}/mesh/config.yaml.
# State:  ${XDG_STATE_HOME:-~/.local/state}/mesh.
# Both are fixed paths, the same under Claude Code, Grok and Codex. No harness plugin-data
# directory is involved, so an uninstall never deletes the config and a rename never moves it.

set -u

# Bash 4+ required. macOS ships system bash 3.2 — instruct user to `brew install bash`.
# Fast-fail here so users get a clear message instead of `declare: -A: invalid option`
# from validate_models (or any other 4+ feature) deep in the call stack.
[ "${BASH_VERSINFO[0]:-0}" -ge 4 ] || {
    echo "config-loader: bash 4+ required (got ${BASH_VERSION:-unknown}). Install: brew install bash" >&2
    exit 1
}

CONFIG_FILE="${MESH_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/mesh/config.yaml}"
PLUGIN_DATA="${XDG_STATE_HOME:-$HOME/.local/state}/mesh"

die() {
    echo "config-loader: $*" >&2
    exit 1
}

warn() {
    # Echoes its arguments to stderr verbatim — callers are responsible for the
    # content being safe to print (config values pass the charset guards before
    # they reach a warn call).
    echo "config-loader: WARN: $*" >&2
}

# Forward-compatible identifier charsets (fix waves 3+5, single source of truth).
# The leading-alnum anchor rejects flag-injection (values starting with -/./:/@);
# all three sets exclude `|` (the model|level pipe protocol) and anything unsafe for
# shell substitution in the executor skills. No enum — a new model or level must
# never require a validator change.
IDENT_RE='^[A-Za-z0-9][A-Za-z0-9._:@-]*$'    # reasoning levels, claude.models, runtime.dispatch_model
MODEL_RE='^[A-Za-z0-9][A-Za-z0-9._:@/-]*$'   # engine models: adds "/" for provider-qualified ids
# grok.models is NARROWER than IDENT_RE, and deliberately so: a grok model name becomes a path
# component (runs/grok/<model>/) and a watch-runs.sh roster entry, and that script's own
# validation is ^[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)*$ — a ':' or '@' accepted here would be
# rejected there, after the run had already been written somewhere the watcher cannot name.
GROK_IDENT_RE='^[A-Za-z0-9][A-Za-z0-9._-]*$'
# Set by validate_defaults when a preset REFERENCES grok and the catalog does not validate.
# The preset read then degrades grok alone instead of dying, and cmd_get_defaults reports it
# through `grok_degraded` so `default` mode can say out loud that the reviewer it was asked
# for is not running. Never consulted on the strict path: validate_grok runs before
# validate_defaults in validate_all and dies there first.
GROK_CATALOG_BROKEN=0

require_yq() {
    # Presence only. WHICH yq this is has stopped mattering: the transcode below tries both
    # known JSON invocations and keeps the one whose output jq can parse, so a flavor check
    # here would only be able to reject binaries that work.
    # The substring "yq not found" is matched by preflight-env.sh's CONFIG_DETAIL
    # toolchain-cause check — do not reword it.
    command -v yq >/dev/null 2>&1 || die "yq not found. mesh-exec accepts either flavor: \
Python-yq (kislyuk/yq — 'pipx install yq') or Go-yq v4+ (mikefarah/yq — 'apt install yq', \
'brew install yq'). Install either one."
}

require_gnu_coreutils() {
    # mesh-exec uses GNU-only utilities: `timeout`, `stdbuf`, `setsid`, `stat -c`, `find`.
    # On macOS these are absent by default (BSD find lacks `-printf`; BSD stat uses `-f`; no `timeout`
    # without coreutils; no `setsid` without util-linux). Users must install GNU coreutils + util-linux
    # + findutils via Homebrew and put gnubin first in PATH. Fast-fail with concrete instructions.
    case "$(uname -s)" in
        Darwin)
            local missing=""
            # `find` is also required (some skills shell out to `find ... -mtime ...`). We check
            # that `find` exists; the supervised-mode loop was rewritten to use `ls -t` so we no
            # longer depend on GNU `find -printf` specifically.
            for tool in timeout stdbuf stat setsid find; do
                if ! command -v "$tool" >/dev/null 2>&1; then
                    missing="$missing $tool"
                fi
            done
            # GNU `stat -c` test catches BSD-vs-GNU divergence even if `stat` itself is present.
            if command -v stat >/dev/null 2>&1 && ! stat -c %Y "$0" >/dev/null 2>&1; then
                missing="$missing stat(GNU)"
            fi
            if [ -n "$missing" ]; then
                die "macOS detected but GNU coreutils/util-linux/findutils not first in PATH (missing:$missing). Install: 'brew install bash coreutils util-linux findutils' then prepend gnubin to PATH: 'export PATH=\"\$(brew --prefix)/opt/coreutils/libexec/gnubin:\$(brew --prefix)/opt/util-linux/sbin:\$(brew --prefix)/opt/util-linux/bin:\$(brew --prefix)/opt/findutils/libexec/gnubin:\$PATH\"' (add to your shell rc)."
            fi
            ;;
    esac
}

# Python-yq (kislyuk/yq) is a jq wrapper: its DEFAULT output is already JSON. Go-yq (mikefarah)
# v4 prints YAML unless told -o=json. We do not ask which one is installed — the only property
# the snapshot needs is "this invocation returned JSON", and that is checked rather than
# guessed. The order is not arbitrary: the python-yq form goes first so the historically
# recommended flavor pays nothing for the fallback.
# `jq .` and NOT `jq -e .`: on an empty snapshot -e returns rc=4 while plain jq returns 0, and
# an empty or comment-only config.yaml legitimately transcodes to zero bytes — see
# validate_providers, where an empty snapshot is handled explicitly.
yq_to_json() {                       # $1 = source YAML, $2 = destination JSON
    yq '.'         "$1" > "$2" 2>/dev/null && jq . "$2" >/dev/null 2>&1 && return 0
    yq -o=json '.' "$1" > "$2" 2>/dev/null && jq . "$2" >/dev/null 2>&1 && return 0
    return 1
}

YQ_SCALARS_1_2='"string","string","boolean","number"'
# The one property that accepting a second flavor can break: off/on/yes/no must stay STRINGS
# (YAML 1.2 core). A YAML-1.1 resolver turns them into booleans, and validate_codex's type die,
# validate_defaults' membership check, and Test 45 then read that as a type error or a failed
# membership test — the user is told to quote a value that was already correct. Checked against
# the binary that is actually installed, not inferred from a version number.
# SETS YQ_PROBE_TYPES; does NOT print. A `die` inside a $(...) substitution would exit only the
# SUBSHELL and the caller would read the empty result as "this yq cannot emit JSON" — a tmpfile
# failure reported as a toolchain verdict. An empty YQ_PROBE_TYPES must mean one thing only.
yq_probe() {
    YQ_PROBE_TYPES=""
    local d
    d=$(mktemp -d -t mesh-yqprobe-XXXXXX) || die "mktemp failed for the yq probe"
    printf 'a: off\nb: yes\nc: true\nd: 3\n' > "$d/probe.yaml"
    yq_to_json "$d/probe.yaml" "$d/probe.json" \
        && YQ_PROBE_TYPES=$(jq -r '[.a,.b,.c,.d|type]|@csv' "$d/probe.json" 2>/dev/null)
    rm -rf "$d"
}

load_or_die() {
    # iter-2 CONCERN-11: "config not found" gets a DISTINCT exit code (2) so
    # user-invoked commands like /do-plan can tolerate the genuinely-tolerable
    # "no config yet" case during first-run, while every other class of error
    # (yaml malformed, env binaries missing, validator die) still fast-fails
    # via the canonical `die` (rc=1). See `commands/do-plan.md` Step 1 for the
    # consumer side. Do NOT fold this into `die` — it must stay distinguishable.
    if [ ! -f "$CONFIG_FILE" ]; then
        echo "config.yaml not found at $CONFIG_FILE." >&2
        # Up to 0.15.0 the config lived in Claude Code's plugin-data dir. Name the move instead
        # of the generic advice when that copy is still there — the first run after the rename
        # lands here. Only the message changes: nothing is copied, the file is the user's.
        local old="" d
        for d in "$HOME"/.claude/plugins/data/claude-mesh-*/config.yaml; do
            [ -f "$d" ] && { old="$d"; break; }
        done
        if [ -n "$old" ]; then
            echo "The claude-mesh config is still at $old. Move it:" >&2
            echo "  mkdir -p \"${CONFIG_FILE%/*}\" && cp \"$old\" \"$CONFIG_FILE\" && chmod 600 \"$CONFIG_FILE\"" >&2
        else
            echo "Copy config.example.yaml from the mesh-exec plugin directory there and fill in your providers." >&2
        fi
        exit 2
    fi
    require_yq
    require_gnu_coreutils
    command -v jq >/dev/null 2>&1 || die "jq not found. Install: 'apt install jq' or 'brew install jq' (jq is universal — same on Linux and macOS)."

    # CONCERN-3 + CONCERN-12: snapshot the yaml to a JSON tmpfile and read everything
    # downstream through jq on the snapshot. This (a) eliminates mid-edit race
    # (the loader sees one consistent version for the duration of one call) and
    # (b) replaces ~30+ yq invocations with one yq + N jq calls (jq is much faster
    # and ships everywhere). Every downstream read is a jq expression over the
    # SNAPSHOT, so jq is the only thing those expressions must be valid for —
    # whichever `yq` transcoded the file stops mattering the moment the JSON
    # exists. The loader no longer needs its `yq` to be a jq wrapper.
    CONFIG_JSON=$(mktemp -t mesh-cfg-XXXXXX.json) || die "mktemp failed for config snapshot"
    chmod 600 "$CONFIG_JSON"
    # Cleanup runs even on `die` because die exits non-zero and the EXIT trap fires. Armed HERE,
    # before anything that can exit, and not after the transcode block: yq_probe dies of its own
    # `mktemp -d` with the snapshot already written, and that snapshot is config.yaml transcoded —
    # plaintext provider tokens included. Mode 600 decides WHO can read it; only this trap decides
    # HOW LONG it exists. The explicit `rm -f`s in the block below are kept: they shorten the
    # window further by removing the file before the probe runs rather than at exit.
    # NOTE: bash EXIT traps do NOT stack — if a caller later sets its own `trap … EXIT`
    # it REPLACES this one. That is why cmd_export (Task 8) must manage its own
    # $CONFIG_JSON / $ENV_FILE cleanup explicitly rather than relying on this trap.
    trap 'rm -f "$CONFIG_JSON"' EXIT
    # ONE yq -> $CONFIG_JSON, then every read via jq on the snapshot. Which of the two JSON
    # invocations does the transcoding is decided by yq_to_json, not by this call site.
    if yq_to_json "$CONFIG_FILE" "$CONFIG_JSON"; then
        # A YAML-1.1 resolver differs from YAML-1.2-core by ONE thing that reaches this schema:
        # it turns off/on/yes/no into booleans. Such a divergence therefore always shows up AS A
        # BOOLEAN IN THE SNAPSHOT. No booleans means no divergence was possible on this
        # document, whichever binary produced it — a property of the artifact, not an inference
        # about who ran. Gating on "which form won" instead would be an identity check smuggled
        # back in: a flavor whose DEFAULT output is JSON wins with the first form and skips this
        # entirely. Measured 2026-08-25: config.example.yaml and the installed config.yaml both
        # hold ZERO booleans, so on a real config the probe never runs.
        # ${bools:-0} guards the same case as $count in validate_providers — an empty
        # snapshot prints nothing.
        local bools
        bools=$(jq '[paths(type=="boolean")] | length' "$CONFIG_JSON" 2>/dev/null)
        if [ "${bools:-0}" -gt 0 ]; then
            yq_probe
            if [ "$YQ_PROBE_TYPES" != "$YQ_SCALARS_1_2" ]; then
                rm -f "$CONFIG_JSON"
                die "yq mis-resolves YAML scalars: off/on/yes/no must stay strings (YAML 1.2 \
core), but this yq turned them into booleans. mesh-exec needs Python-yq (kislyuk/yq) or \
Go-yq v4+ (mikefarah/yq). Got: $(yq --version 2>&1 | head -1)"
            fi
        fi
    else
        rm -f "$CONFIG_JSON"
        # The transcode failed: is that the yq's fault or the yaml's? The probe runs a document
        # that is known to be good, so it separates the two. Before this split every failure
        # here read "check yaml syntax" and sent the operator to edit a healthy file.
        yq_probe
        if [ -n "$YQ_PROBE_TYPES" ]; then
            die "config snapshot: yaml→json conversion failed for $CONFIG_FILE (check yaml syntax)"
        else
            die "yq cannot produce JSON: neither 'yq .' nor 'yq -o=json .' returned JSON for a \
known-good document. mesh-exec accepts Python-yq (kislyuk/yq — 'pipx install yq') or Go-yq \
v4+ (mikefarah/yq — 'apt install yq', 'brew install yq'). Got: $(yq --version 2>&1 | head -1)"
        fi
    fi
}

validate_providers() {
    local count
    # CONCERN-12: null-coalesce so `providers: null` (or `providers: ~`) doesn't yield
    # "integer expression expected" on the next line. An EMPTY config.yaml is nastier
    # still: the JSON snapshot is an empty stream, jq emits nothing at all and $count
    # is "" — default it to 0 so the check below dies cleanly instead of spraying
    # bash arithmetic noise first (fix wave 5).
    count=$(jq '(.providers // []) | length' "$CONFIG_JSON" 2>/dev/null)
    [ "${count:-0}" -gt 0 ] || die "providers: section is empty or missing"

    # Per-provider checks
    local i=0
    local seen_pids=""   # line-based accumulator (no bash-4 associative arrays)
    while [ "$i" -lt "$count" ]; do
        local id label base_url token kind
        id=$(jq -r ".providers[$i].id // \"\"" "$CONFIG_JSON")
        label=$(jq -r ".providers[$i].label // \"\"" "$CONFIG_JSON")
        base_url=$(jq -r ".providers[$i].base_url // \"\"" "$CONFIG_JSON")
        token=$(jq -r ".providers[$i].token // \"\"" "$CONFIG_JSON")
        kind=$(jq -r ".providers[$i].kind // \"anthropic-api\"" "$CONFIG_JSON")

        [ -n "$id" ] || die "providers[$i].id: missing or empty"
        [[ "$id" =~ ^[a-z0-9-]+$ ]] || die "providers[$i].id: must match [a-z0-9-]+, got \"$id\""

        # Duplicate-id detection (Design §5 rule).
        case " $seen_pids " in
            *" $id "*) die "providers[$id]: duplicate id (defined twice)" ;;
        esac
        seen_pids="$seen_pids $id"

        [ -n "$label" ] || die "providers[$id].label: missing"
        case "$label" in *"|"*) die "providers[$id].label: must not contain '|' (breaks pipe-format list output)" ;; esac
        # A newline breaks the same output in a worse way than '|' does: consumers read
        # list-models a line at a time, so the continuation becomes a whole phantom entry.
        # In preflight-env.sh's table it lands as a row whose NAME contains spaces, which
        # shifts an arbitrary word into the status column — a word that can read AUTH-FAILED
        # and pass a closed-set check nothing ever measured.
        case "$label" in *$'\n'*) die "providers[$id].label: must not contain a newline (breaks line-based list output)" ;; esac
        [ -n "$base_url" ] || die "providers[$id].base_url: missing"
        # iter-3 CONCERN-4: design §5 promises invalid-URL rejection, not just emptiness
        case "$base_url" in
            http://*|https://*) ;;
            *) die "providers[$id].base_url: invalid URL \"$base_url\" (must start with http:// or https://)" ;;
        esac
        [ -n "$token" ] || die "providers[$id].token: empty (replace REPLACE_ME)"
        # NOTE: REPLACE_ME placeholder check moved to cmd_export per iter-2 CONCERN-10.
        # Rationale: validate checks structural correctness; export checks readiness-for-use.
        # This lets config.example.yaml (which ships with REPLACE_ME) pass `validate` —
        # important for Task 21 Test 13 (validate the example). Fast-fail at export time
        # still gives users a clear pre-HTTP error.

        case "$kind" in
            anthropic-api|ollama-daemon) ;;
            *) die "providers[$id].kind: unknown value \"$kind\". Valid: anthropic-api, ollama-daemon" ;;
        esac

        i=$((i+1))
    done
}

validate_models() {
    local count
    count=$(jq '.models | length' "$CONFIG_JSON" 2>/dev/null || echo 0)
    [ "$count" -gt 0 ] || die "models: section is empty or missing"

    # Collect provider ids for cross-reference
    local provider_ids
    provider_ids=$(jq -r '.providers[].id' "$CONFIG_JSON" | tr '\n' ' ')

    local i=0
    local seen_ids=""   # line-based accumulator (no bash-4 associative arrays)
    while [ "$i" -lt "$count" ]; do
        local id label model
        id=$(jq -r ".models[$i].id // \"\"" "$CONFIG_JSON")
        label=$(jq -r ".models[$i].label // \"\"" "$CONFIG_JSON")
        model=$(jq -r ".models[$i].model // \"\"" "$CONFIG_JSON")

        [ -n "$id" ] || die "models[$i].id: missing"

        # slash check
        if [[ "$id" != */* ]]; then
            die "models[$i].id: must be \"<provider>/<short>\", got \"$id\""
        fi

        # multiple slashes
        local slash_count=$(echo "$id" | tr -cd '/' | wc -c)
        if [ "$slash_count" -gt 1 ]; then
            die "models[$i].id: only one \"/\" allowed in id, got \"$id\""
        fi

        local provider_prefix="${id%%/*}"
        local short="${id#*/}"

        [ -n "$short" ] || die "models[$i].id: short name after \"/\" is empty (id=\"$id\")"
        [[ "$short" =~ ^[a-z0-9._-]+$ ]] || die "models[$id].id: short name must match [a-z0-9._-]+, got \"$short\""

        # Provider must exist. Quoted case-membership (same idiom as the dup-check below):
        # both the list and the needle are double-quoted, so this is glob/word-split safe
        # regardless of contents — it does not rely on validate_providers having
        # normalized provider ids first.
        case " $provider_ids " in
            *" $provider_prefix "*) ;;
            *) die "models[$id] references missing provider \"$provider_prefix\"" ;;
        esac

        # Duplicate id check (line-based, no associative array).
        case " $seen_ids " in
            *" $id "*) die "models[$id]: duplicate id (defined twice)" ;;
        esac
        seen_ids="$seen_ids $id"

        [ -n "$label" ] || die "models[$id].label: missing"
        case "$label" in *"|"*) die "models[$id].label: must not contain '|'" ;; esac
        # Same reason as the providers check above — a newline turns one model into two entries,
        # the second of which is printed as a row name and parsed as a status.
        case "$label" in *$'\n'*) die "models[$id].label: must not contain a newline (breaks line-based list output)" ;; esac
        [ -n "$model" ] || die "models[$id].model: required field missing or empty"

        i=$((i+1))
    done
}

# Per-section validators: get-codex / get-gemini validate ONLY their own section
# (typed-getter principle — a malformed gemini: section must not block codex
# resolution and vice versa; Codex PR-review finding). validate_all runs both.
validate_codex() {
    # Type-dispatch gate (fix wave 5): the old `jq -e '.codex'` truthiness probe
    # skipped a scalar section entirely, so `codex: false` passed validate and
    # later crashed cmd_get_codex with a raw jq "Cannot index boolean" (rc=5).
    # null — key absent, empty `codex:` key, or an empty config snapshot — keeps
    # the absent semantics; any other non-mapping type dies cleanly here.
    local stype
    stype=$(jq -r '.codex | type' "$CONFIG_JSON" 2>/dev/null)
    case "$stype" in
        ""|null) return 0 ;;
        object) ;;
        *) die "codex: must be a mapping with model/reasoning_level keys (got $stype)" ;;
    esac
    local mtype ltype model level
    # Type + charset guards (fix wave 3, external review): pass-through must stay
    # a *string* pass-through. A non-string value (unquoted `reasoning_level: 3`,
    # YAML booleans `true`/`false`) used to survive validation and then crash
    # cmd_get_codex with a raw jq type error; unsafe characters would corrupt the
    # `model|level` pipe protocol or shell substitution in the executor skills.
    # (Note: under every yq flavor this loader accepts — the transcode verifies it — the YAML-1.1 words
    # `off`/`on`/`yes`/`no` parse as STRINGS and take the warn-and-pass-through path below, not the type die —
    # empirically locked by Test 45.) Same forward-compatible charset family as
    # runtime.dispatch_model — no enum, new models/levels never require a
    # validator change; codex.model additionally allows "/" for
    # provider-qualified ids like `openai/gpt-oss-20b` (fix wave 5).
    # Single snapshot read (fix wave 5 refactor): one jq call fetches all four
    # values/types (was 4 calls); @tsv escapes embedded tabs/newlines so the read
    # below cannot desync (the charset guards reject such values anyway; a die on
    # a non-string type fires before its garbled value column is ever used).
    local fields
    fields=$(jq -r '[(.codex.model | type), (.codex.model // ""),
                     (.codex.reasoning_level | type), (.codex.reasoning_level // "")] | @tsv' "$CONFIG_JSON")
    IFS=$'\t' read -r mtype model ltype level <<< "$fields"
    case "$mtype" in
        string) ;;
        null) die "codex.model: required when codex: section present" ;;
        *) die "codex.model: must be a string (got $mtype)" ;;
    esac
    [ -n "$model" ] || die "codex.model: required when codex: section present"
    [[ "$model" =~ $MODEL_RE ]] \
        || die "codex.model: must start with a letter/digit and match [A-Za-z0-9._:@/-], got \"$model\""
    case "$ltype" in
        string|null) ;;
        *) die "codex.reasoning_level: must be a string (got $ltype) — quote it, e.g. reasoning_level: \"ultra\"" ;;
    esac
    if [ -n "$level" ]; then
        [[ "$level" =~ $IDENT_RE ]] \
            || die "codex.reasoning_level: must start with a letter/digit and match [A-Za-z0-9._:@-], got \"$level\""
        case "$level" in
            # Known today (OpenAI server-accepted set as of 2026-07). New levels
            # ship with new models (gpt-5.6 added `ultra`) — an unknown value is
            # NOT an error: warn and pass through; the codex CLI/API is the final
            # validator and rejects truly invalid values with a clear HTTP 400.
            none|minimal|low|medium|high|xhigh|ultra) ;;
            *) warn "codex.reasoning_level: unknown value \"$level\" — passing through (codex CLI will validate)" ;;
        esac
    fi
}

validate_gemini() {
    # Same type-dispatch gate as validate_codex (fix wave 5): a scalar `gemini:`
    # section used to skip validation and crash cmd_get_gemini with a raw jq
    # error. (Full type/charset parity for gemini.model stays on the fix-later
    # list — this closes only the gate class.)
    local stype model
    stype=$(jq -r '.gemini | type' "$CONFIG_JSON" 2>/dev/null)
    case "$stype" in
        ""|null) return 0 ;;
        object) ;;
        *) die "gemini: must be a mapping with a model key (got $stype)" ;;
    esac
    model=$(jq -r '.gemini.model // ""' "$CONFIG_JSON")
    [ -n "$model" ] || die "gemini.model: required when gemini: section present"
}

# Split in THREE on purpose, and each seam pays for itself.
#
# validate_grok vs validate_grok_catalog: validate_defaults needs the CATALOG validated before
# it can check preset membership, and it runs after validate_all has already validated the
# section — so the half that can `warn` must not be on that path, or every run with an unknown
# effort prints the warning twice. Same discipline the header of validate_claude spells out.
#
# validate_grok_section_type vs validate_grok_catalog: the grok check on the validate_defaults
# path is LAZY, and that is the whole point. cmd_get_defaults calls validate_defaults,
# preflight-env.sh derives CONFIG_STATUS from `get-defaults design_review`, and both
# orchestrators read `get-defaults` before anything else — so validating the grok CATALOG
# unconditionally there would make a typo in `grok.models` print CONFIG INVALID and SKIP every
# codex and gemini row. That is the failure preflight-env.sh forbids in so many words ("a
# broken optional section fails its own row, never the whole environment"), and the shape of
# the `ultra` incident cmd_export records — the reason has_codex and has_gemini are bare
# probes. So validate_defaults runs the TYPE GATE unconditionally (jq must never meet
# `grok: false`) and the full catalog check only when the preset actually references grok —
# `grok` in `builtin`, or a non-empty `grok_models`. Nothing is weakened: validate_all still
# validates the catalog for `config-loader.sh validate`, and list-grok-models / get-grok are
# typed getters that fail loudly for anyone who asks for the catalog itself.
validate_grok_section_type() {
    # Its own function because validate_defaults needs THIS half on every run — so jq never
    # meets `grok: false` — while paying for the catalog check only when a preset actually
    # references grok. validate_defaults is the ONLY caller of the gate ALONE: validate_grok
    # does not call it directly — it reaches it through validate_grok_catalog, which does — so
    # validate_all, has_grok, list-grok-models and get-grok all keep the full check.
    #
    # Type-dispatch gate, same class as validate_codex/validate_gemini: a scalar section must
    # die cleanly instead of crashing the getters with a raw jq "Cannot index boolean" (rc=5).
    local stype
    stype=$(jq -r '.grok | type' "$CONFIG_JSON" 2>/dev/null)
    # `grok:` written with NO value (YAML null) counts as ABSENT, not as "present but empty".
    # That is the established precedent, not a new choice: `codex:` with no value already
    # yields has_codex=0 rather than a "model required" error, and a user who comments out a
    # section's body means "off", not "misconfigured".
    case "$stype" in
        ""|null) return 0 ;;
        object) ;;
        *) die "grok: must be a mapping with models/reasoning_effort keys (got $stype)" ;;
    esac
}

validate_grok_catalog() {
    validate_grok_section_type
    # The gate returns 0 for BOTH "no section" and "a well-formed mapping", so ask again which
    # one it was: there is no catalog to require where there is no section. The order is not
    # interchangeable — `jq -e` reports `grok: false` as untrue too, so probing first would
    # read a scalar section as "absent" and skip the very check the gate exists to force.
    jq -e '.grok' "$CONFIG_JSON" >/dev/null 2>&1 || return 0

    # DELIBERATE ASYMMETRY with claude:, where a section without `models` simply means "no
    # catalog". Here the catalog is REQUIRED: the grok reviewer agent stops without a MODEL,
    # so a section with no models advertises a reviewer that cannot start. Closer to
    # codex.model / gemini.model, which are required for the same kind of reason.
    local mtype
    mtype=$(jq -r '.grok.models | type' "$CONFIG_JSON" 2>/dev/null)
    case "$mtype" in
        array) ;;
        null) die "grok.models: required when grok: section present" ;;
        *) die "grok.models: must be a list of grok model ids, got $mtype" ;;
    esac
    [ "$(jq '.grok.models | length' "$CONFIG_JSON")" -gt 0 ] \
        || die "grok.models: required when grok: section present"

    # The narrow charset, not IDENT_RE — see GROK_IDENT_RE. The "grok-4.6" example is passed
    # from here for the same reason validate_claude passes "opus": the shared helper must stay
    # engine-agnostic.
    validate_model_catalog '.grok.models' 'grok.models' "$GROK_IDENT_RE" '[A-Za-z0-9._-]' 'grok-4.6'
}

validate_grok() {
    validate_grok_catalog
    validate_grok_effort
    validate_grok_model_efforts
}

# The section-wide default. Split out of validate_grok for one reason only: its early returns
# — an absent or empty key is a legal "let the CLI decide" — would otherwise skip the per-model
# table that now follows it. The body below is unchanged; its messages are pinned by tests.
validate_grok_effort() {
    # reasoning_effort mirrors codex.reasoning_level, including the pass-through: xAI adds
    # levels with new models, and the CLI rejects a truly invalid one by name.
    local ltype effort
    ltype=$(jq -r '.grok.reasoning_effort | type' "$CONFIG_JSON" 2>/dev/null)
    case "$ltype" in
        ""|null) return 0 ;;
        string) ;;
        *) die "grok.reasoning_effort: must be a string (got $ltype) — quote it, e.g. reasoning_effort: \"xhigh\"" ;;
    esac
    effort=$(jq -r '.grok.reasoning_effort' "$CONFIG_JSON")
    # Empty string == key not set, the codex.reasoning_level semantics. A user who comments a
    # value out and leaves `reasoning_effort: ""` behind means "let the CLI decide", and dying
    # on that would be stricter than the section this one is modelled on.
    [ -n "$effort" ] || return 0
    [[ "$effort" =~ $IDENT_RE ]] \
        || die "grok.reasoning_effort: must start with a letter/digit and match [A-Za-z0-9._:@-], got \"$effort\""
    case "$effort" in
        # Known today (verified against grok 1.0.5). New levels ship with new models, so an
        # unknown value is NOT an error: warn and pass through, exactly as codex.reasoning_level
        # does — the grok CLI is the final validator. Never turn this into an enum.
        # Canonical copy of this list: config.example.yaml's grok.reasoning_effort comment.
        # The README row is the third. All three move together.
        low|medium|high|xhigh|max) ;;
        *) warn "grok.reasoning_effort: unknown value \"$effort\" — passing through (the grok CLI will validate)" ;;
    esac
}

# Per-model overrides of the level above. The grok CLI validates --effort PER MODEL and rejects
# a bad pair at argument parsing (rc=1) BEFORE any API call — measured 2026-08-30 against grok
# 1.0.5: grok-4.6 accepts xhigh|high|medium|low, grok-4.5 only high|medium|low, and most proxied
# entries all five — so one section-wide level cannot serve a catalog of several models.
#
# Validated HERE and not in validate_grok_catalog. What that means, MEASURED rather than
# assumed: `validate`, `get-grok`, preflight's grok row AND `has_grok` all see a broken table —
# has_grok runs validate_grok, which calls this function, so it exits 1 — while
# `list-grok-models` alone does not. Do not restate it as "has_grok does not validate this":
# that was the OLD contract, and it is the one that produced "grok offered, run dir created,
# get-grok dies, STALLED, re-dispatch". Deliberate, and not a weaker gate: `reasoning_effort`
# sits on exactly that path, a new key does not invent a stricter one than the key it sits
# beside, and the laziness is what keeps a broken grok: section from grounding a codex-only
# review — the `ultra` incident, named rather than cited by line number, because that number has
# already gone stale once.
validate_grok_model_efforts() {
    local mtype count i=0 key vtype value
    mtype=$(jq -r '.grok.model_efforts | type' "$CONFIG_JSON" 2>/dev/null)
    case "$mtype" in
        ""|null) return 0 ;;
        object) ;;
        *) die "grok.model_efforts: must be a mapping of <model id> to <effort> (got $mtype)" ;;
    esac
    count=$(jq '.grok.model_efforts | length' "$CONFIG_JSON")
    while [ "$i" -lt "$count" ]; do
        key=$(jq -r ".grok.model_efforts | keys_unsorted[$i]" "$CONFIG_JSON")
        # Every key must name a catalog entry — the twin of the defaults.<preset>.grok_models
        # membership rule. A key outside the catalog does nothing whatsoever, and a user who
        # believes a model runs at the level they wrote is the exact failure this key exists to
        # prevent. `index` yields 0 on a first-position match, which jq counts as true.
        jq -e --arg m "$key" '(.grok.models // []) | index($m)' "$CONFIG_JSON" >/dev/null 2>&1 \
            || die "grok.model_efforts: \"$key\" is not in grok.models — every key must name a catalog entry"
        vtype=$(jq -r --arg m "$key" '.grok.model_efforts[$m] | type' "$CONFIG_JSON")
        [ "$vtype" = "string" ] \
            || die "grok.model_efforts[\"$key\"]: must be a string (got $vtype) — quote it, e.g. $key: \"xhigh\""
        value=$(jq -r --arg m "$key" '.grok.model_efforts[$m]' "$CONFIG_JSON")
        # Empty == unset, the reasoning_effort semantics: fall back to the section default.
        if [ -n "$value" ]; then
            [[ "$value" =~ $IDENT_RE ]] \
                || die "grok.model_efforts[\"$key\"]: must start with a letter/digit and match [A-Za-z0-9._:@-], got \"$value\""
            case "$value" in
                # Same WARN-and-pass as reasoning_effort, for the same reason: the CLI is the
                # final validator and its accepted set differs per model. Never an enum.
                low|medium|high|xhigh|max) ;;
                *) warn "grok.model_efforts[\"$key\"]: unknown value \"$value\" — passing through (the grok CLI will validate)" ;;
            esac
        fi
        i=$((i+1))
    done
}

# Shared by claude: and grok: — the two sections that expose a LIST of model names the
# orchestrators fan independent reviewers out over. The four guards below are what the two
# lists must never diverge on, and each of them is here because it once mattered:
#   - element type: `jq -r` stringifies a number/boolean, so an unquoted `- 5` would compare
#     as the string "5" downstream and a catalog of ["5"] would accept a preset of [5];
#   - empty value: an empty entry makes the membership glob *"  "* match against an EMPTY
#     catalog, silently accepting anything;
#   - charset: it forbids the space that a missing comma produces, which is what stops a
#     preset entry from SPANNING two adjacent catalog members in the substring membership
#     test ("opus fable" matched " opus fable ");
#   - duplicates: two reviewers with one name are indistinguishable in every attribution
#     table both orchestrators print.
# PRECONDITION: the CALLER must have type-gated $1 to `array` first — this helper does not. A
# scalar has a length of its own (`jq '"opus" | length'` is 4), so on `models: opus` the loop
# below would enter, index a string with a number, and report `[0]: must be a string (got )`
# with jq's raw "Cannot index string with number" beside it, instead of the caller's clean
# "must be a list". validate_claude and validate_grok_catalog each gate before they call.
# MUST stay side-effect free (no warn): validate_defaults calls it again after validate_all.
# $1 = jq path to the list, $2 = message label, $3 = charset regex, $4 = charset for the message,
# $5 = an example model name for the element-type message (OPTIONAL). Given, that message ends
# `— quote it, e.g. - "<$5>"`; omitted, the clause is dropped entirely, because any example
# baked into the shared string would be claude-specific and wrong for half the callers.
# Never hardcode "opus" here — validate_claude passes it, which is what keeps its text frozen.
validate_model_catalog() {
    local jq_path="$1" label="$2" charset_re="$3" charset_display="$4" example="${5:-}"
    local type_hint=""
    [ -n "$example" ] && type_hint=" — quote it, e.g. - \"$example\""
    local count i=0 seen=""   # line-based accumulator (no bash-4 associative arrays)
    count=$(jq "$jq_path | length" "$CONFIG_JSON")
    while [ "$i" -lt "$count" ]; do
        local etype v
        etype=$(jq -r "${jq_path}[$i] | type" "$CONFIG_JSON")
        [ "$etype" = "string" ] \
            || die "${label}[$i]: must be a string (got $etype)$type_hint"
        v=$(jq -r "${jq_path}[$i]" "$CONFIG_JSON")
        [ -n "$v" ] || die "${label}[$i]: empty value"
        [[ "$v" =~ $charset_re ]] \
            || die "${label}[$i]: must start with a letter/digit and match $charset_display (a model alias or id), got \"$v\""
        case " $seen " in
            *" $v "*) die "${label}[$i]: duplicate model \"$v\" (two reviewers would be indistinguishable)" ;;
        esac
        seen="$seen $v"
        i=$((i+1))
    done
}

validate_claude() {
    # MAY BE CALLED SEVERAL TIMES per loader invocation — validate_all calls it directly,
    # and validate_defaults calls it again before its catalog membership check. It must
    # therefore stay SIDE-EFFECT-FREE: no warn to stderr, no state, nothing a user would
    # see twice. (validate_codex does warn about reasoning_level; do not copy that here
    # without first making the call sites idempotent.)
    #
    # Type-dispatch gate, same class as validate_codex/validate_gemini (fix wave 5):
    # a scalar `claude:` section must die cleanly instead of crashing the getters with
    # a raw jq "Cannot index boolean" (rc=5). null — key absent or an explicitly empty
    # key — keeps the absent semantics.
    #
    # DELIBERATE ASYMMETRY with codex:/gemini:: those sections are GATES (no section ⇒
    # `builtin: [codex]` is a hard error). `claude:` is NOT a gate — the builtin claude
    # reviewer has no external dependency and works with no section at all. This section
    # only widens it to several models.
    local stype
    stype=$(jq -r '.claude | type' "$CONFIG_JSON" 2>/dev/null)
    case "$stype" in
        ""|null) return 0 ;;
        object) ;;
        *) die "claude: must be a mapping with a models key (got $stype)" ;;
    esac

    local mtype
    mtype=$(jq -r '.claude.models | type' "$CONFIG_JSON" 2>/dev/null)
    case "$mtype" in
        null) return 0 ;;
        array) ;;
        *) die "claude.models: must be a list of Claude model aliases, got $mtype" ;;
    esac

    # Same forward-compatible charset as runtime.dispatch_model — no enum, a new
    # Claude model must never require a validator change. The leading-alnum anchor
    # rejects flag-injection (-opus/.foo). The "opus" example is passed from here,
    # not baked into the shared helper, so grok: gets no claude-flavoured wording.
    validate_model_catalog '.claude.models' 'claude.models' "$IDENT_RE" '[A-Za-z0-9._:@-]' 'opus'
}

validate_defaults() {
    if ! jq -e '.defaults' "$CONFIG_JSON" >/dev/null 2>&1; then
        return 0
    fi

    # claude_models entries are checked against the claude.models catalog below, so the
    # catalog must be a well-formed list FIRST. validate_claude is cheap and idempotent
    # (validate_all calls it directly too, and it MUST stay side-effect-free for that
    # reason — see its own header).
    #
    # It also guards the VERY NEXT LINE: on a scalar section such as `claude: false`,
    # `jq -r '(.claude.models // [])[]'` dies with "Cannot index boolean with string",
    # and cmd_get_defaults — which runs ONLY this validator, per the typed-getter
    # principle — would surface that raw jq noise instead of a clean message. (Note the
    # protection stops there: cmd_get_defaults itself only ever indexes
    # `.defaults.<category>.*` and never touches `.claude`.)
    validate_claude

    # The grok TYPE GATE, unconditionally — and deliberately NOT validate_grok_catalog, nor
    # validate_grok. Unconditional because the catalog READ below is conditional: on
    # `grok: false`, `(.grok.models // [])[]` dies with raw jq "Cannot index boolean" noise,
    # and WHETHER jq meets that scalar would otherwise depend on which preset is being
    # validated. The gate is one `jq type` call, cheap enough to pay for on every run, which is
    # the whole reason it is a function of its own.
    #
    # Run in a SUBSHELL so its die() ends that subshell rather than this process. On THIS path a
    # malformed section degrades grok alone (the branch below), because grounding the preset read
    # takes codex and gemini down with grok over a typo in a user-owned file — the `ultra`
    # incident's shape, and the one thing preflight-env.sh forbids in so many words. `grok: false`
    # is how a user tries to switch a section OFF without deleting it, so it is a likely typo, not
    # an exotic one. The same reasoning already governs a broken CATALOG (8c8583f); a section of
    # the wrong TYPE is the other half of that breakage and now shares its treatment. Strictness
    # is unchanged where it belongs: validate_all still runs the full validate_grok, and has_grok
    # / list-grok-models / get-grok still exit 1 — which is what makes preflight-env.sh print
    # INVALID on the grok row rather than a MISSING one.
    # The GATE HALF ONLY because this validator is what cmd_get_defaults runs, preflight-env.sh
    # derives CONFIG_STATUS from `get-defaults design_review`, and both orchestrators read
    # get-defaults before anything else: validating the grok CATALOG here would make one typo
    # in grok.models print CONFIG INVALID and skip every codex and gemini row — the `ultra`
    # incident's shape, spelled out in the header above validate_grok_section_type. The catalog
    # is checked per preset below, only for a preset that actually references grok. And never
    # validate_grok here: it can warn, this call site is reached twice per run (validate_all,
    # then cmd_get_defaults), so its unknown-effort warning would print twice.
    local grok_type_err grok_type_broken=0
    grok_type_err=$(validate_grok_section_type 2>&1) || grok_type_broken=1

    local claude_catalog
    claude_catalog=$(jq -r '(.claude.models // [])[]' "$CONFIG_JSON" | tr '\n' ' ')

    # NOT read beside claude_catalog, on purpose. The read is cheap, but it belongs with the
    # validation it depends on, and that validation must not run for a config whose presets
    # never mention grok (see the gate call above). Both are done inside the preset loop, and
    # grok_catalog_read memoises them so two grok-using presets pay for the catalog once.
    local grok_catalog="" grok_catalog_read=0
    # grok_catalog_read=1 is the load-bearing half of the type degrade: it is what stops the
    # conditional catalog read below from ever reaching `(.grok.models // [])[]` on a scalar
    # section — precisely the raw jq noise the gate exists to prevent. Note it cannot be left to
    # validate_grok_catalog's own `jq -e '.grok' || return 0` probe: `jq -e` exits 1 on the value
    # `false`, so a scalar section would read there as ABSENT and the read would proceed.
    # GROK_CATALOG_BROKEN=1 then does the rest, exactly as for a catalog that will not parse: the
    # membership test is skipped, and cmd_get_defaults drops grok from the preset it emits and
    # reports grok_degraded to the preset that asked for it.
    if [ "$grok_type_broken" -eq 1 ]; then
        GROK_CATALOG_BROKEN=1
        grok_catalog_read=1
        warn "the grok: section does not validate — grok is disabled for this read, every other engine is unaffected. The section says: ${grok_type_err#config-loader: }"
    fi

    local has_codex has_gemini has_grok
    has_codex=$(jq -e '.codex' "$CONFIG_JSON" >/dev/null 2>&1 && echo 1 || echo 0)
    has_gemini=$(jq -e '.gemini' "$CONFIG_JSON" >/dev/null 2>&1 && echo 1 || echo 0)
    # A bare PROBE like the two above, answering only "is there a section for the builtin arm
    # to point at" — not `get-flag has_grok`, which validates the catalog because it promises
    # a dispatchable reviewer. The catalog behind this one is validated lazily below.
    has_grok=$(jq -e '.grok' "$CONFIG_JSON" >/dev/null 2>&1 && echo 1 || echo 0)

    local model_ids
    model_ids=$(jq -r '(.models // [])[].id' "$CONFIG_JSON" | tr '\n' ' ')

    local presets=("code_review" "design_review")
    local preset
    for preset in "${presets[@]}"; do
        if ! jq -e ".defaults.$preset" "$CONFIG_JSON" >/dev/null 2>&1; then
            continue
        fi

        # Guard: builtin/models must be lists when present (a scalar slips past the
        # length-based loop and — with the quoted case-membership test — an empty
        # indexed value would false-accept. Fail closed with a clear message.)
        local btype mtype
        btype=$(jq -r ".defaults.$preset.builtin | type" "$CONFIG_JSON")
        case "$btype" in
            array|null) ;;
            *) die "defaults.$preset.builtin: must be a list, got $btype" ;;
        esac
        mtype=$(jq -r ".defaults.$preset.models | type" "$CONFIG_JSON")
        case "$mtype" in
            array|null) ;;
            *) die "defaults.$preset.models: must be a list, got $mtype" ;;
        esac

        # builtin entries
        local builtin_count
        builtin_count=$(jq ".defaults.$preset.builtin | length" "$CONFIG_JSON" 2>/dev/null || echo 0)
        local b=0
        while [ "$b" -lt "$builtin_count" ]; do
            local v
            v=$(jq -r ".defaults.$preset.builtin[$b]" "$CONFIG_JSON")
            case "$v" in
                claude) ;;
                native) ;;
                codex)
                    [ "$has_codex" = "1" ] || die "defaults.$preset.builtin lists \"codex\" but no codex: section"
                    ;;
                gemini)
                    [ "$has_gemini" = "1" ] || die "defaults.$preset.builtin lists \"gemini\" but no gemini: section"
                    ;;
                grok)
                    # The `|| [ "$grok_type_broken" -eq 1 ]` arm is not a hole in the fail-closed
                    # rule: it separates "no grok: section at all", which this rule exists to
                    # catch, from "a section that is present but malformed", which the type
                    # degrade above has already reported and whose grok entries cmd_get_defaults
                    # is already stripping. $has_grok cannot tell them apart — it comes from
                    # `jq -e '.grok'`, and `jq -e` exits 1 on the value `false` — so without this
                    # the degrade would be undone one screen later, by a die that grounds every
                    # other engine and prints a second, wronger message about the same typo.
                    [ "$has_grok" = "1" ] || [ "$grok_type_broken" -eq 1 ] \
                        || die "defaults.$preset.builtin lists \"grok\" but no grok: section"
                    ;;
                *) die "defaults.$preset.builtin: unknown value \"$v\" (valid: claude, native, codex, gemini, grok)" ;;
            esac
            b=$((b+1))
        done

        # model entries
        local m_count
        m_count=$(jq ".defaults.$preset.models | length" "$CONFIG_JSON" 2>/dev/null || echo 0)
        local m=0
        while [ "$m" -lt "$m_count" ]; do
            local mid
            mid=$(jq -r ".defaults.$preset.models[$m]" "$CONFIG_JSON")
            # Quoted case-membership (glob/word-split safe; same idiom as validate_models'
            # provider check). cmd_get_defaults calls validate_defaults WITHOUT validate_models,
            # so $model_ids is not pre-normalized — quoting both sides is required here.
            case " $model_ids " in
                *" $mid "*) ;;
                *) die "defaults.$preset.models[$m]: unknown model \"$mid\"" ;;
            esac
            m=$((m+1))
        done

        # claude_models entries — the built-in claude reviewer fanned out over several
        # Claude models. Same shape as the models[] check above: type gate, membership in
        # the catalog, no duplicates.
        local cmtype
        cmtype=$(jq -r ".defaults.$preset.claude_models | type" "$CONFIG_JSON")
        case "$cmtype" in
            array|null) ;;
            *) die "defaults.$preset.claude_models: must be a list, got $cmtype" ;;
        esac

        local cm_count
        # No `|| echo 0` fallback: the type gate above already rejects everything except
        # array and null, and `null | length` is 0 in jq with rc=0 — not an error. A
        # fallback here would be dead code suggesting a failure mode that cannot occur.
        cm_count=$(jq ".defaults.$preset.claude_models | length" "$CONFIG_JSON")
        if [ "$cm_count" -gt 0 ]; then
            # Fail closed: a claude_models list with no "claude" in builtin is almost
            # certainly a typo, and a SILENTLY IGNORED list is exactly the bug this
            # feature fixes in mesh-design-review. Never repeat it here.
            local claude_in_builtin
            claude_in_builtin=$(jq "[(.defaults.$preset.builtin // [])[] | select(. == \"claude\")] | length" "$CONFIG_JSON")
            [ "$claude_in_builtin" -gt 0 ] \
                || die "defaults.$preset.claude_models is set but \"claude\" is missing from defaults.$preset.builtin (add \"claude\" to builtin, or drop claude_models)"
        fi

        # <!-- SYNC: this loop has a deliberate TWIN below — the grok_models loop. Four places
        # move together: this loop, that one, and the two `<!-- SYNC: -->` markers naming them.
        # Change the membership test, the uniqueness set or the element-type gate here and the
        # same change is due there. The marker below carries the full rationale for why the two
        # are hand-written twins rather than one shared consumer helper. -->
        local c=0
        local seen_cm=""
        while [ "$c" -lt "$cm_count" ]; do
            local cmetype cmv
            # Element type gate — same check validate_claude does on the catalog. Without
            # it `jq -r` stringifies a number/boolean/null and the membership test below
            # compares that string, so a catalog of ["5","true"] would accept a preset of
            # [5, true]. Unquoted `[true]`/`[false]` DO parse as booleans and land here;
            # `[yes]`/`[no]`/`[on]`/`[off]` do NOT — under every yq flavor this loader accepts
            # — the transcode verifies it — those are the STRINGS "yes"/"no"/"on"/"off", so
            # the membership check below is what reports them.
            # Same behaviour the note at validate_codex records, empirically locked by Test 45.
            cmetype=$(jq -r ".defaults.$preset.claude_models[$c] | type" "$CONFIG_JSON")
            [ "$cmetype" = "string" ] \
                || die "defaults.$preset.claude_models[$c]: must be a string (got $cmetype) — quote it, e.g. - \"opus\""
            cmv=$(jq -r ".defaults.$preset.claude_models[$c]" "$CONFIG_JSON")
            # MUST precede the membership test. `tr '\n' ' '` leaves $claude_catalog
            # EMPTY when there is no catalog (jq emits an empty stream), so
            # " $claude_catalog " is "  " — and an empty $cmv makes the glob *"  "*
            # match, silently ACCEPTING an empty entry even with no catalog at all.
            # validate_models has the same guard for the same reason
            # (`[ -n "$id" ] || die`).
            [ -n "$cmv" ] || die "defaults.$preset.claude_models[$c]: empty value"
            # Charset gate — the SAME check validate_claude runs on the catalog, and
            # the reason the membership test below cannot be spanned. Membership is a
            # substring match against the space-joined catalog, so without this a
            # multi-token value whose words happen to be ADJACENT catalog members
            # false-accepts: catalog [opus, fable] + `claude_models: ["opus fable"]` (a
            # missing comma — YAML flow yields ONE string) matched " opus fable " and
            # validated clean. Rejecting the space here makes the span impossible, and
            # keeps both sides of the catalog⊇preset relation validated identically.
            [[ "$cmv" =~ $IDENT_RE ]] \
                || die "defaults.$preset.claude_models[$c]: must start with a letter/digit and match [A-Za-z0-9._:@-] (a model alias or id), got \"$cmv\""
            # Quoted case-membership (glob/word-split safe), same idiom as the models[]
            # check above. An absent catalog makes $claude_catalog empty, so every entry
            # lands here — hence the "add it to the claude.models catalog" hint.
            case " $claude_catalog " in
                *" $cmv "*) ;;
                *) die "defaults.$preset.claude_models[$c]: unknown claude model \"$cmv\" (add it to the claude.models catalog)" ;;
            esac
            case " $seen_cm " in
                *" $cmv "*) die "defaults.$preset.claude_models[$c]: duplicate model \"$cmv\"" ;;
            esac
            seen_cm="$seen_cm $cmv"
            c=$((c+1))
        done

        # native_models — host-agnostic reviewer slugs. One-way pairing like claude_models:
        # a non-empty list requires "native" in builtin; native without the list is valid
        # (the host CLI lists what is available). Charset is GROK_IDENT_RE: slugs become
        # path components. No catalog membership — these names live on the host, not here.
        local nmtype
        nmtype=$(jq -r ".defaults.$preset.native_models | type" "$CONFIG_JSON")
        case "$nmtype" in
            array|null) ;;
            *) die "defaults.$preset.native_models: must be a list, got $nmtype" ;;
        esac

        local nm_count
        nm_count=$(jq ".defaults.$preset.native_models | length" "$CONFIG_JSON")
        if [ "$nm_count" -gt 0 ]; then
            local native_in_builtin
            native_in_builtin=$(jq "[(.defaults.$preset.builtin // [])[] | select(. == \"native\")] | length" "$CONFIG_JSON")
            [ "$native_in_builtin" -gt 0 ] \
                || die "defaults.$preset.native_models is set but \"native\" is missing from defaults.$preset.builtin (add \"native\" to builtin, or drop native_models)"
        fi

        local n=0
        local seen_nm=""
        while [ "$n" -lt "$nm_count" ]; do
            local nmetype nmv
            nmetype=$(jq -r ".defaults.$preset.native_models[$n] | type" "$CONFIG_JSON")
            [ "$nmetype" = "string" ] \
                || die "defaults.$preset.native_models[$n]: must be a string (got $nmetype) — quote it, e.g. - \"grok-4.6\""
            nmv=$(jq -r ".defaults.$preset.native_models[$n]" "$CONFIG_JSON")
            [ -n "$nmv" ] || die "defaults.$preset.native_models[$n]: empty value"
            [[ "$nmv" =~ $GROK_IDENT_RE ]] \
                || die "defaults.$preset.native_models[$n]: must start with a letter/digit and match [A-Za-z0-9._-] (a host model slug), got \"$nmv\""
            case " $seen_nm " in
                *" $nmv "*) die "defaults.$preset.native_models[$n]: duplicate model \"$nmv\"" ;;
            esac
            seen_nm="$seen_nm $nmv"
            n=$((n+1))
        done

        # grok_models — the same shape as claude_models, with the requirement running BOTH ways.
        # claude tolerates "claude in builtin, no claude_models": it falls back to one reviewer
        # on the dispatch model. grok has no such fallback — its reviewer agent stops without a
        # MODEL — so the missing list is an error rather than a default.
        local gmtype
        gmtype=$(jq -r ".defaults.$preset.grok_models | type" "$CONFIG_JSON")
        case "$gmtype" in
            array|null) ;;
            *) die "defaults.$preset.grok_models: must be a list, got $gmtype" ;;
        esac

        local gm_count grok_in_builtin
        # No `|| echo 0` fallback, for the reason the claude_models block above records: the
        # type gate leaves only array and null, and `null | length` is 0 in jq with rc=0.
        gm_count=$(jq ".defaults.$preset.grok_models | length" "$CONFIG_JSON")
        grok_in_builtin=$(jq "[(.defaults.$preset.builtin // [])[] | select(. == \"grok\")] | length" "$CONFIG_JSON")

        # THE LAZY POINT, and the reason grok_catalog is not read with claude_catalog: the
        # catalog is validated and read only once THIS preset is known to reference grok — by
        # naming it in builtin, or by carrying a non-empty grok_models. A preset that mentions
        # grok nowhere reaches neither, so a broken grok catalog cannot ground the codex and
        # gemini rows that `get-defaults` feeds (see the gate call at the top of this
        # function). Test 57 holds the standing regressions — unreferenced-broken-grok.yaml
        # and broken-grok-valid-codex.yaml must both keep `get-defaults code_review` at rc=0
        # while `validate` rejects them; if either goes red, this stopped being lazy. It runs
        # BEFORE the two emptiness rules below so a broken catalog reports its OWN error
        # instead of "grok_models is empty", and grok_catalog_read keeps the second preset
        # from repeating the work.
        #
        # And when this preset DOES reference grok, a broken catalog still must not ground the
        # read. `validate_grok_catalog` dies; here it is run in a subshell so its message is
        # captured instead, grok is dropped from what this preset dispatches, and claude, codex
        # and gemini carry on. The alternative — dying — made ONE typo in a user-owned file
        # print CONFIG INVALID, SKIP every preflight row and stop an orchestration that had not
        # asked for grok at all, which is the `ultra` incident's exact shape and the thing the
        # laziness above exists to prevent. It is also what commands/mesh-review.md Step 1
        # already assumes: it degrades grok alone on a bad section and says so. Strictness is
        # not lost — `validate` runs validate_grok on the full path and rejects the config, and
        # has_grok / list-grok-models / get-grok still exit 1, which is what makes
        # preflight-env.sh print INVALID on the grok row rather than a MISSING one.
        if { [ "$gm_count" -gt 0 ] || [ "$grok_in_builtin" -gt 0 ]; } && [ "$grok_catalog_read" -eq 0 ]; then
            local grok_catalog_err
            # validate_grok, not validate_grok_catalog: a preset that references grok must
            # degrade on ANY reason grok cannot be dispatched, and a broken model_efforts table
            # is such a reason. Still in the subshell, so the message is captured and grok is
            # dropped from this preset alone — every other engine is unaffected, which is the
            # whole point of the branch. It can also `warn` (an unknown effort level); that
            # warning is captured here rather than printed, which is why the UNCONDITIONAL gate
            # above still must not call this function: that call site runs twice per read and
            # would print such a warning twice.
            if grok_catalog_err=$(validate_grok 2>&1); then
                grok_catalog=$(jq -r '(.grok.models // [])[]' "$CONFIG_JSON" | tr '\n' ' ')
            else
                GROK_CATALOG_BROKEN=1
                grok_catalog=""
                warn "defaults.$preset references grok but the grok: section does not validate — grok is disabled in defaults.$preset, every other engine is unaffected, and a preset that does not name grok is untouched. (validate_defaults walks the whole defaults: block on every read, so this line can name a preset you did not ask for.) The loader says: ${grok_catalog_err#config-loader: }"
            fi
            grok_catalog_read=1
        fi

        # -gt/-eq throughout, never `= 0`: these are jq integers, and the claude block beside
        # this one uses the arithmetic form everywhere. Mixing the string and arithmetic
        # comparators for the same values invites a future `= 00` that silently never matches.
        # Both rules are fatal only while grok can still RUN. Their whole purpose is to stop the
        # orchestrator dispatching a grok reviewer the agent then refuses to start for want of a
        # MODEL — so when GROK_CATALOG_BROKEN is 1 they guard against something that cannot
        # happen: the degrade below strips grok from builtin and empties grok_models, and no grok
        # reviewer is dispatched at all. What the die DOES do in that state is ground codex,
        # gemini and claude — one line after the WARN above has promised, in as many words, that
        # "every other engine is unaffected". That is the `ultra` incident's shape, and closing it
        # is what 8c8583f and eaf3ad4 already did for the two neighbouring cases.
        #
        # BOTH rules, not just the emptiness one: measured 2026-08-30, a broken catalog reaches
        # each of them and each answers with the same WARN-then-die pair. Fixing one would leave
        # the other stating the contradiction.
        #
        # `validate` is untouched, and not by argument: validate_all runs validate_grok BEFORE
        # validate_defaults and dies there, so GROK_CATALOG_BROKEN is never 1 on the strict path
        # and this branch is unreachable from it. Measured on all three broken shapes — every one
        # still exits 1 from `config-loader.sh validate`.
        grok_preset_die() {
            if [ "$GROK_CATALOG_BROKEN" -eq 1 ]; then
                warn "$1 — reported and NOT fatal for that preset: the grok: section does not validate either, so grok is dropped from it whatever the preset says. Fix both; \`config-loader.sh validate\` still rejects the file."
            else
                die "$1"
            fi
        }
        if [ "$gm_count" -gt 0 ] && [ "$grok_in_builtin" -eq 0 ]; then
            grok_preset_die "defaults.$preset.grok_models is set but \"grok\" is missing from defaults.$preset.builtin (add \"grok\" to builtin, or drop grok_models)"
        fi
        if [ "$grok_in_builtin" -gt 0 ] && [ "$gm_count" -eq 0 ]; then
            grok_preset_die "defaults.$preset.builtin lists \"grok\" but defaults.$preset.grok_models is empty — a grok reviewer cannot start without a model (name one from the grok.models catalog)"
        fi

        # <!-- SYNC: this preset loop is the deliberate TWIN of the claude_models loop above.
        # Four places move together: that loop, this one, and the two `<!-- SYNC: -->` markers
        # naming them. Editing the membership test, the uniqueness set or the element-type gate
        # in one WITHOUT the other is the defect this marker exists to catch in review.
        #
        # Why twins rather than one shared helper, deliberately: the guard that actually
        # matters here — the charset rule that stops a preset entry SPANNING two adjacent
        # catalog members in the substring membership test `*" $entry "*` — already lives in
        # the shared validate_model_catalog, so the dangerous half IS unified. What is
        # duplicated is the consumer: a membership test over an already-validated catalog,
        # whose drift costs a differing error message and is caught by the first run of either
        # suite. Merging these two would pull the claude preset messages into the same
        # byte-identity freeze that Task 1 is already spending its risk budget on, to remove a
        # duplication whose failure mode is cosmetic. Revisit once that freeze is lifted. -->
        local g=0
        local seen_gm=""
        while [ "$g" -lt "$gm_count" ]; do
            local gmetype gmv
            # EVERY rule in this loop goes through grok_preset_die, not bare die. When the
            # catalog does not validate, grok has already been stripped from this preset and
            # grok_degraded set, so these rules guard a dispatch that cannot happen — while a
            # bare die grounded the whole read, one line after the WARN above promised "every
            # other engine is unaffected". That is the `ultra` shape 8c8583f, eaf3ad4 and
            # 0c7188a each removed from a neighbouring case; the per-ELEMENT rules were the
            # half left behind. The earlier comment here argued they "need no catalog", which
            # is true and beside the point: the question is not whether the rule CAN run
            # without one, but whether it should be fatal for codex and gemini once grok is
            # already switched off. With a healthy catalog every rule below stays fatal.
            #
            # `validate` is unaffected, measured not argued: validate_all runs validate_grok
            # first and dies on the catalog itself, so all three broken shapes still exit 1
            # from the strict path and never reach this loop.
            #
            # Each failed check skips the REST of this entry. grok_preset_die returns when it
            # only warns, so without the skip one malformed entry would report itself two or
            # three times over — a non-string that is then charset-checked as the text jq
            # printed for it, an empty value that then fails the charset rule as well.
            gmetype=$(jq -r ".defaults.$preset.grok_models[$g] | type" "$CONFIG_JSON")
            if [ "$gmetype" != "string" ]; then
                grok_preset_die "defaults.$preset.grok_models[$g]: must be a string (got $gmetype) — quote it, e.g. - \"grok-4.6\""
                g=$((g+1)); continue
            fi
            gmv=$(jq -r ".defaults.$preset.grok_models[$g]" "$CONFIG_JSON")
            # MUST precede the membership test, same as in the claude twin: an empty $gmv
            # makes the glob *"  "* match an EMPTY catalog and silently accept the entry.
            if [ -z "$gmv" ]; then
                grok_preset_die "defaults.$preset.grok_models[$g]: empty value"
                g=$((g+1)); continue
            fi
            # GROK_IDENT_RE, not IDENT_RE — the narrow charset the catalog itself is held to,
            # so both sides of the catalog⊇preset relation stay validated identically.
            if ! [[ "$gmv" =~ $GROK_IDENT_RE ]]; then
                grok_preset_die "defaults.$preset.grok_models[$g]: must start with a letter/digit and match [A-Za-z0-9._-] (a grok model id), got \"$gmv\""
                g=$((g+1)); continue
            fi
            # Skipped when the catalog did not validate: there is nothing to be a member OF,
            # and this preset's grok entries are dropped by cmd_get_defaults anyway.
            if [ "$GROK_CATALOG_BROKEN" -eq 0 ]; then
                case " $grok_catalog " in
                    *" $gmv "*) ;;
                    *) die "defaults.$preset.grok_models[$g]: unknown grok model \"$gmv\" (add it to the grok.models catalog)" ;;
                esac
            fi
            case " $seen_gm " in
                *" $gmv "*) grok_preset_die "defaults.$preset.grok_models[$g]: duplicate model \"$gmv\"" ;;
            esac
            seen_gm="$seen_gm $gmv"
            g=$((g+1))
        done

        # run_mode (only for code_review)
        if [ "$preset" = "code_review" ]; then
            local rm_val
            rm_val=$(jq -r ".defaults.$preset.run_mode // \"\"" "$CONFIG_JSON")
            if [ -n "$rm_val" ]; then
                case "$rm_val" in
                    background|team) ;;
                    *) die "defaults.$preset.run_mode: unknown value \"$rm_val\" (valid: background, team)" ;;
                esac
            fi
        fi
    done
}

validate_runtime() {
    # Type-dispatch gates (fix wave 6, Codex PR-review P2): same class as the
    # validate_codex/validate_gemini gates from wave 5. The old `jq -e '.runtime'`
    # truthiness probe let `runtime: false` skip validation entirely (silent rc=0),
    # and a non-mapping `runtime.timeouts` passed the per-key loop below with raw
    # jq "Cannot index boolean" noise; both then crashed cmd_get_runtime (rc=5) —
    # which the mesh-review/mesh-design-review watch loops call for
    # timeouts.global_sec. null — key absent or an explicitly empty key — keeps
    # the absent semantics; any other non-mapping type dies cleanly here.
    local stype
    stype=$(jq -r '.runtime | type' "$CONFIG_JSON" 2>/dev/null)
    case "$stype" in
        ""|null) return 0 ;;
        object) ;;
        *) die "runtime: must be a mapping of runtime settings (got $stype)" ;;
    esac
    local ttype
    ttype=$(jq -r '.runtime.timeouts | type' "$CONFIG_JSON" 2>/dev/null)
    case "$ttype" in
        ""|null) ;;
        object) ;;
        *) die "runtime.timeouts: must be a mapping with single_run_sec/stall_sec/global_sec/max_retries keys (got $ttype)" ;;
    esac

    local drm
    drm=$(jq -r '.runtime.default_run_mode // ""' "$CONFIG_JSON")
    if [ -n "$drm" ]; then
        case "$drm" in
            background|team) ;;
            *) die "runtime.default_run_mode: unknown value \"$drm\" (valid: background, team)" ;;
        esac
    fi

    local mrd
    mrd=$(jq -r '.runtime.max_redispatch // ""' "$CONFIG_JSON")
    if [ -n "$mrd" ]; then
        [[ "$mrd" =~ ^[1-9][0-9]*$ ]] \
            || die "runtime.max_redispatch: must be positive integer, got \"$mrd\""
    fi

    local dm
    dm=$(jq -r '.runtime.dispatch_model // ""' "$CONFIG_JSON")
    if [ -n "$dm" ]; then
        # Forward-compatible: any model alias (opus/fable/…) or full id, including
        # cloud-provider ids — Bedrock (e.g. us.anthropic.…-v2:0, colon) and Vertex
        # (e.g. claude-opus-4@date, at-sign). No enum — a new model must never require a
        # validator change. The leading-char anchor still rejects a value starting with
        # -/./:/@ (flag-injection); the charset keeps it safe through jq/bash downstream.
        [[ "$dm" =~ $IDENT_RE ]] \
            || die "runtime.dispatch_model: must start with a letter/digit and match [A-Za-z0-9._:@-] (a model alias or id), got \"$dm\""
    fi

    local key
    for key in single_run_sec stall_sec global_sec max_retries; do
        local v
        v=$(jq -r ".runtime.timeouts.$key // \"\"" "$CONFIG_JSON")
        if [ -n "$v" ]; then
            [[ "$v" =~ ^[1-9][0-9]*$ ]] || die "runtime.timeouts.$key: must be positive integer, got \"$v\""
        fi
    done
}

validate_all() {
    # Single source of truth for the full validation pipeline.
    # Order matters: providers first (models reference providers), then models, then
    # the per-engine sections, then sections that reference BOTH models and the claude
    # catalog (defaults), then runtime.
    validate_providers
    validate_models
    validate_codex
    validate_gemini
    validate_grok
    validate_claude
    validate_defaults
    validate_runtime
}

cmd_validate() {
    load_or_die
    validate_all
    # do-plan left for the session-relay plugin, which has a config of its own. The key is
    # still accepted, so a config copied over from claude-mesh validates as it is; `validate`
    # names it once so it gets cleaned up — the getters stay quiet, they run many times a run.
    if [ -n "$(jq -r '.runtime.do_plan_default_stop_tokens // ""' "$CONFIG_JSON")" ]; then
        warn "runtime.do_plan_default_stop_tokens is ignored: do-plan moved to the session-relay plugin — set stop_tokens in ~/.config/session-relay/config.yaml and delete this key"
    fi
}

cmd_export() {
    local model_id="${1:-}"
    [ -n "$model_id" ] || die "export: model id required (e.g. zai/glm)"

    load_or_die
    # Scoped validation (CRITICAL-10, revised 2026-07-10): fast-fail malformed
    # providers/models/runtime BEFORE ext-claude-exec spends 30+ minutes — but ONLY
    # the sections export actually reads (runtime for timeouts). Errors in
    # codex:/gemini:/defaults: cannot affect an ext-claude run and must NOT block it:
    # the `ultra` incident (2026-07-10) killed every ext-claude executor over a codex
    # setting. Mirrors the typed-getter principle (iter-2 CONCERN-2/3); cmd_validate
    # remains the full-config lint. Latency cost amortised by the JSON snapshot
    # (CONCERN-12 / Risk #12).
    validate_providers
    validate_models
    validate_runtime

    # iter-3 CRITICAL-1 + SUGGESTION-1: reads via jq on snapshot; REPLACE_ME check before model resolution.
    local provider_id="${model_id%%/*}"

    # Locate provider FIRST so a copied-but-unedited config (REPLACE_ME token) fails
    # promptly with a token error rather than after model-field resolution.
    local p_count j=0 pfound=-1
    p_count=$(jq '.providers | length' "$CONFIG_JSON")
    while [ "$j" -lt "$p_count" ]; do
        local pid
        pid=$(jq -r ".providers[$j].id" "$CONFIG_JSON")
        if [ "$pid" = "$provider_id" ]; then
            pfound="$j"; break
        fi
        j=$((j+1))
    done
    [ "$pfound" -ge 0 ] || die "internal: provider $provider_id missing after validation"

    local base_url token kind
    base_url=$(jq -r ".providers[$pfound].base_url" "$CONFIG_JSON")
    token=$(jq -r ".providers[$pfound].token" "$CONFIG_JSON")
    kind=$(jq -r ".providers[$pfound].kind // \"anthropic-api\"" "$CONFIG_JSON")

    # iter-2 CONCERN-10: REPLACE_ME check lives HERE (not in validate_providers), so that
    # the shipped config.example.yaml — which has REPLACE_ME everywhere — still passes
    # `validate`. The error fires at the moment the user actually tries to USE a provider.
    [ "$token" = "REPLACE_ME" ] && die "providers[$provider_id].token: still \"REPLACE_ME\" — edit $CONFIG_FILE with a real token for provider \"$provider_id\" before exporting"

    # Locate model (after provider + token check so the token error surfaces first).
    local m_count i=0 found=-1
    m_count=$(jq '.models | length' "$CONFIG_JSON")
    while [ "$i" -lt "$m_count" ]; do
        local id
        id=$(jq -r ".models[$i].id" "$CONFIG_JSON")
        if [ "$id" = "$model_id" ]; then
            found="$i"; break
        fi
        i=$((i+1))
    done
    [ "$found" -ge 0 ] || die "export: model \"$model_id\" not found in config"

    local model haiku_model opus_model sonnet_model subagent_model context_window
    model=$(jq -r ".models[$found].model" "$CONFIG_JSON")
    # SECURITY: bind the model fallback as DATA (--arg), not program text. validate_models
    # only checks .model non-empty (no charset), so a value containing `"` or `$` would
    # otherwise break out of the jq string literal and splice in arbitrary expressions
    # (e.g. `.providers[0].token` -> token leak). `\$m` is literal `$m` in the jq program;
    # `--arg m "$model"` binds it as a string. $found stays interpolated — validated integer.
    haiku_model=$(jq -r --arg m "$model" ".models[$found].haiku_model // \$m" "$CONFIG_JSON")
    opus_model=$(jq -r --arg m "$model" ".models[$found].opus_model // \$m" "$CONFIG_JSON")
    sonnet_model=$(jq -r --arg m "$model" ".models[$found].sonnet_model // \$m" "$CONFIG_JSON")
    subagent_model=$(jq -r --arg m "$model" ".models[$found].subagent_model // \$m" "$CONFIG_JSON")
    context_window=$(jq -r ".models[$found].context_window // \"\"" "$CONFIG_JSON")

    # Write export lines to a private tmpfile that the caller `source`s and unlinks.
    # Going through stdout + eval would put the token text in the Bash-tool transcript
    # captured by Claude Code — see CONCERN-1 / Design §11 OQ #2. The tmpfile is created
    # mode 600 BEFORE any sensitive content is written, then closed atomically.

    local env_file
    env_file=$(mktemp -t "mesh-env-XXXXXX.sh") || die "export: mktemp failed"
    chmod 600 "$env_file"
    # Single redirect block so an early die() leaves a half-written file but doesn't
    # leak via the file handle. The caller is responsible for `rm -f` on success and trap-cleanup on failure.
    # Resolve timeouts BEFORE opening the redirect so any jq error fails fast,
    # not silently into the env file. Defaults match Design §4 values.
    local t_single t_stall t_global t_retries
    t_single=$(jq  -r '.runtime.timeouts.single_run_sec // 1800' "$CONFIG_JSON")
    t_stall=$(jq   -r '.runtime.timeouts.stall_sec // 600'       "$CONFIG_JSON")
    t_global=$(jq  -r '.runtime.timeouts.global_sec // 3600'     "$CONFIG_JSON")
    t_retries=$(jq -r '.runtime.timeouts.max_retries // 2'       "$CONFIG_JSON")
    # Timestamp via the bash builtin (no external `date`): GNU `date -Iseconds` is not
    # portable to BSD-`date` macOS, and require_gnu_coreutils does NOT verify `date`.
    # `%()T` printf format is bash 4.2+ (universal where we already require bash 4+).
    local now
    printf -v now '%(%Y-%m-%dT%H:%M:%S%z)T' -1

    {
        printf '# mesh env — created %s for model %s — sensitive, delete after source\n' "$now" "$model_id"
        printf 'export ANTHROPIC_BASE_URL=%q\n' "$base_url"
        printf 'export ANTHROPIC_AUTH_TOKEN=%q\n' "$token"
        printf 'export ANTHROPIC_API_KEY=""\n'
        printf 'export ANTHROPIC_MODEL=%q\n' "$model"
        printf 'export ANTHROPIC_DEFAULT_OPUS_MODEL=%q\n' "$opus_model"
        printf 'export ANTHROPIC_DEFAULT_SONNET_MODEL=%q\n' "$sonnet_model"
        printf 'export ANTHROPIC_DEFAULT_HAIKU_MODEL=%q\n' "$haiku_model"
        printf 'export CLAUDE_CODE_SUBAGENT_MODEL=%q\n' "$subagent_model"
        printf 'export CLAUDE_CODE_USE_BEDROCK=""\n'
        printf 'export CLAUDE_CODE_USE_VERTEX=""\n'
        printf 'export CLAUDE_CODE_ATTRIBUTION_HEADER="0"\n'
        if [ -n "$context_window" ]; then
            printf 'export CLAUDE_CODE_AUTO_COMPACT_WINDOW=%q\n' "$context_window"
        else
            # Explicit unset prevents value from a prior `source` leaking across models.
            printf 'unset CLAUDE_CODE_AUTO_COMPACT_WINDOW\n'
        fi
        # Plugin-specific signal for skills to route precheck
        printf 'export CLAUDE_MESH_PROVIDER_KIND=%q\n' "$kind"
        # Task 2.5: export the resolved data dir so skills that source this env file get the
        # same self-discovered path the loader used (CLAUDE_PLUGIN_DATA is empty in skill Bash calls).
        printf 'export CLAUDE_MESH_DATA_DIR=%q\n' "$PLUGIN_DATA"
        # Timeouts exported so default mode and supervised mode read identical values.
        printf 'export CLAUDE_MESH_TIMEOUT_SINGLE_RUN_SEC=%q\n' "$t_single"
        printf 'export CLAUDE_MESH_TIMEOUT_STALL_SEC=%q\n'      "$t_stall"
        printf 'export CLAUDE_MESH_TIMEOUT_GLOBAL_SEC=%q\n'     "$t_global"
        printf 'export CLAUDE_MESH_TIMEOUT_MAX_RETRIES=%q\n'    "$t_retries"
    } > "$env_file"

    # The only output to stdout is the path — the transcript captures the path,
    # never the contents (which include the token).
    printf '%s\n' "$env_file"
}

cmd_get_flag() {
    # Query existence of optional config sections AND read small scalar config
    # values without bypassing the loader. Used by /mesh-review (feature gating) and
    # the mesh-exec wrappers.
    #
    # Output: "1"/"0" for has_* boolean flags, scalar value (string/integer) for
    #         documented getters. The exact contract is per-case.
    # Exit:   0 for every documented feature once the config loads — load_or_die
    #         still owns rc=2 ("no config.yaml"). die() fires (rc=1) on an unknown
    #         feature name AND from the three validator-backed cases
    #         (has_claude_models, has_grok, dispatch_model),
    #         which surface the validator's own message on a malformed section:
    #         a consumer telling "absent" from "broken" must check rc, not stdout.
    local feature="${1:-}"
    load_or_die
    case "$feature" in
        has_codex)
            jq -e '.codex' "$CONFIG_JSON" >/dev/null 2>&1 && echo 1 || echo 0
            ;;
        has_gemini)
            jq -e '.gemini' "$CONFIG_JSON" >/dev/null 2>&1 && echo 1 || echo 0
            ;;
        has_grok)
            # VALIDATES BEFORE READING, like has_claude_models below and unlike the bare probes
            # has_codex / has_gemini above. The difference is what each flag PROMISES, not
            # inconsistency: has_codex answers "is there a codex section" — its model is a
            # single scalar with a documented fallback, so presence is the whole question.
            # has_grok is consumed as "can a grok reviewer be dispatched", which requires a
            # non-empty, valid catalog, because the reviewer agent stops without a MODEL. That
            # is the same promise has_claude_models makes, and the reason no separate
            # has_grok_models flag is needed — a bare probe would make that false. Do NOT
            # "restore parity" by simplifying this to `jq -e '.grok'`.
            #
            # validate_grok, not validate_grok_catalog: `model_efforts` and a typed
            # `reasoning_effort` make dispatch impossible exactly as an unusable catalog does,
            # so a flag that promises "can be dispatched" has to see them. It answered 1 on a
            # broken table until all three reviewers of this branch found the same hole
            # independently — grok was offered, dispatched, and died on `get-grok "$MODEL"`
            # AFTER its run dir existed, which the guard reads as STALLED, "killed mid-flight",
            # and STALLED means re-dispatch: a max_redispatch round on an error no retry fixes.
            #
            # This is NOT the `ultra` incident returning. rc=1 here is what both orchestrators
            # already handle by degrading grok ALONE and printing this validator's own message,
            # and what makes preflight print INVALID on the grok row instead of MISSING. The
            # unconditional type gate at the top of validate_defaults is untouched, so a broken
            # section NO preset references still grounds nothing.
            validate_grok
            jq -e '.grok' "$CONFIG_JSON" >/dev/null 2>&1 && echo 1 || echo 0
            ;;
        has_models)
            jq -e '.models[0]' "$CONFIG_JSON" >/dev/null 2>&1 && echo 1 || echo 0
            ;;
        has_claude_models)
            # Non-empty claude.models catalog? Gates the Claude-model selection page in
            # /mesh-review and /mesh-design-review. Unlike the bare-probe has_* cases
            # above, this VALIDATES BEFORE READING, so a malformed `claude:` section
            # fails loudly with the validator's own message instead of a raw jq read on
            # `claude: false` exiting 5 ("Cannot index boolean") and that rc being
            # swallowed by `|| echo 0` into a bogus "no catalog". (Indexing depth is NOT
            # the distinction — has_models probes `.models[0]`, inside its section too,
            # and deliberately does not validate.) Mirrors the typed-getter cases below.
            validate_claude
            jq -e '.claude.models[0]' "$CONFIG_JSON" >/dev/null 2>&1 && echo 1 || echo 0
            ;;
        has_defaults_code_review)
            jq -e '.defaults.code_review' "$CONFIG_JSON" >/dev/null 2>&1 && echo 1 || echo 0
            ;;
        dispatch_model)
            # Optional. Empty output = no value set → the caller omits model: on dispatch
            # and the subagent inherits the session model. validate_runtime owns the
            # field's charset check, so run it BEFORE reading: load_or_die does not invoke
            # validators (iter-2 CRITICAL-2), and each typed getter calls only the validator
            # that owns its section (iter-2 CONCERN-2/3). The bare-probe has_* cases above
            # skip validation on purpose: a single `jq -e` probe whose rc IS the answer.
            validate_runtime
            jq -r '.runtime.dispatch_model // empty' "$CONFIG_JSON"
            ;;
        *)
            die "get-flag: unknown feature \"$feature\" (valid: has_codex, has_gemini, has_grok, has_models, has_claude_models, has_defaults_code_review, dispatch_model)"
            ;;
    esac
}

cmd_list_models() {
    # Emit "<id>|<label>" per model (one line each). Used by /mesh-review Step 3
    # pagination to avoid bypassing the loader with raw yq calls.
    load_or_die
    validate_providers
    validate_models
    jq -r '.models[]? | .id + "|" + (.label // .id)' "$CONFIG_JSON"
}

cmd_list_claude_models() {
    # Emit one Claude model alias per line, in config order. Unlike cmd_list_models there
    # is NO "<id>|<label>" pair: a Claude alias (opus / fable / …) is self-describing, so
    # the catalog is a flat list of strings. If labels are ever needed, the catalog can be
    # widened to {id, label} objects without breaking this line-per-entry contract.
    # Prints nothing (exit 0) when there is no catalog.
    load_or_die
    validate_claude
    jq -r '(.claude.models // [])[]' "$CONFIG_JSON"
}

cmd_list_providers() {
    # Emit "<id>|<label>|<kind>" per provider.
    load_or_die
    validate_providers
    jq -r '.providers[]? | .id + "|" + (.label // .id) + "|" + (.kind // "anthropic-api")' "$CONFIG_JSON"
}

# iter-2 CONCERN-2: typed getters for codex / gemini config — Tasks 13 (codex)
# and 14 (gemini) call these instead of raw `yq` so flavor-detect + JSON snapshot
# apply uniformly. Output: pipe-separated to match cmd_list_* convention.
cmd_get_codex() {
    load_or_die
    validate_codex
    # Format: <model>|<reasoning_level>
    # NOTE: when codex: is absent this still prints a lone "|" (empty model + level), exit 0.
    # Callers (Task 13) must gate on `get-flag has_codex` first, or split on "|" and test the
    # model field — do NOT treat a non-empty raw string as "codex configured".
    jq -r '(.codex.model // "") + "|" + (.codex.reasoning_level // "")' "$CONFIG_JSON"
}

cmd_get_gemini() {
    load_or_die
    validate_gemini
    # Format: <model>
    jq -r '.gemini.model // ""' "$CONFIG_JSON"
}

cmd_list_grok_models() {
    # One grok model id per line, config order — same line-per-entry contract as
    # cmd_list_claude_models. Prints nothing (exit 0) when there is no grok: section.
    load_or_die
    validate_grok_catalog
    jq -r '(.grok.models // [])[]' "$CONFIG_JSON"
}

cmd_get_grok() {
    local model="${1:-}" per
    load_or_die
    validate_grok
    # Format: <reasoning_effort>, empty when unset. Deliberately NOT "<model>|<effort>" like
    # get-codex: grok carries a CATALOG, not one model — read it with list-grok-models. Callers
    # gate on `get-flag has_grok` first, exactly as they do for codex and gemini.
    #
    # With a MODEL argument, grok.model_efforts overrides that default for that one model,
    # because the CLI validates --effort per model and its accepted set differs between them.
    # The argument is OPTIONAL and legitimately EMPTY: grok-exec passes "$MODEL", which is empty
    # on a direct call naming no model, and that asks the whole-section question this command
    # has always answered — so an empty argument must not become a lookup of the empty id. The
    # model is deliberately NOT checked against the catalog here: grok-code-review already
    # refuses a MODEL outside it, and a direct grok-exec call may legitimately name any id.
    if [ -n "$model" ]; then
        per=$(jq -r --arg m "$model" '.grok.model_efforts[$m] // ""' "$CONFIG_JSON")
        if [ -n "$per" ]; then printf '%s\n' "$per"; return 0; fi
    fi
    jq -r '.grok.reasoning_effort // ""' "$CONFIG_JSON"
}

# iter-2 CONCERN-3: typed getter for defaults.<category> — /mesh-review (Task 15a)
# and /mesh-design-review (Task 16) call this instead of raw yq to read the default
# reviewer set. <category> must be one of: code_review, design_review.
cmd_get_defaults() {
    local category="${1:-}"
    case "$category" in
        code_review|design_review) ;;
        *) die "get-defaults: unknown category \"$category\" (valid: code_review, design_review)" ;;
    esac
    load_or_die
    validate_defaults
    # iter-3 CONCERN-1: emit a JSON object so orchestrators get builtin + claude_models +
    # grok_models + native_models + models + run_mode (run_mode meaningful only for
    # code_review) through the loader instead of raw yq. -c = one line. claude_models,
    # grok_models and native_models default to [] and never null — both orchestrators
    # iterate them directly. native is not stripped when grok degrades.
    # grok_degraded: true means the preset named grok but its catalog would not validate, so
    # grok has been REMOVED from builtin and grok_models emptied — the caller must not dispatch
    # a grok reviewer, and in `default` mode must say out loud that it is not running one.
    # False on every healthy config, including one whose broken grok: section no preset touches
    # — and on a preset that does not itself reference grok while its SIBLING does.
    # GROK_CATALOG_BROKEN is ONE variable for the whole run, because validate_defaults walks both
    # presets in a single pass; the flag alone therefore cannot say which preset asked for grok.
    # Emitted unfiltered it told a code_review caller that a reviewer was not running when
    # code_review had never asked for one — spending the only signal that reports a MISSING
    # REQUESTED reviewer on a reviewer nobody requested, and sending the user to edit a user-owned
    # config.yaml over a review that was not degraded at all. $category is already restricted to
    # code_review|design_review at the top of this function, so it is safe to interpolate here
    # exactly as it is in the jq below.
    local grok_refs
    grok_refs=$(jq "([(.defaults.${category}.builtin // [])[] | select(. == \"grok\")] | length) + ((.defaults.${category}.grok_models // []) | length)" "$CONFIG_JSON" 2>/dev/null) || grok_refs=0
    local gd=false
    if [ "$GROK_CATALOG_BROKEN" -eq 1 ] && [ "${grok_refs:-0}" -gt 0 ]; then
        gd=true
    fi
    jq -c --argjson gd "$gd" "{builtin: ((.defaults.${category}.builtin // []) | if \$gd then map(select(. != \"grok\")) else . end), claude_models: (.defaults.${category}.claude_models // []), grok_models: (if \$gd then [] else (.defaults.${category}.grok_models // []) end), native_models: (.defaults.${category}.native_models // []), models: (.defaults.${category}.models // []), run_mode: (.defaults.${category}.run_mode // null), grok_degraded: \$gd}" "$CONFIG_JSON"
}

# iter-3 CONCERN-1: typed getter for runtime UI defaults (default_run_mode), as a JSON
# object. /mesh-review reads these without raw yq.
# timeouts added in fix wave 5: the mesh-review / mesh-design-review disk-watch bounds
# itself by runtime.timeouts.global_sec "via the loader", so the getter must actually
# emit the block. Defaults mirror cmd_export / Design §4 exactly.
cmd_get_runtime() {
    load_or_die
    validate_runtime
    jq -c '{default_run_mode: (.runtime.default_run_mode // "background"),
            max_redispatch: (.runtime.max_redispatch // 1),
            dispatch_model: (.runtime.dispatch_model // ""),
            timeouts: {single_run_sec: (.runtime.timeouts.single_run_sec // 1800),
                       stall_sec: (.runtime.timeouts.stall_sec // 600),
                       global_sec: (.runtime.timeouts.global_sec // 3600),
                       max_retries: (.runtime.timeouts.max_retries // 2)}}' "$CONFIG_JSON"
}

case "${1:-}" in
    validate) cmd_validate ;;
    config-path)
        # WITHOUT load_or_die: callers name this path precisely when there is no config yet.
        printf '%s\n' "$CONFIG_FILE"
        ;;
    data-dir)
        # WITHOUT load_or_die, so skills can compute their runs/ path even on a fresh
        # install (no config.yaml yet).
        printf '%s\n' "$PLUGIN_DATA"
        ;;
    export)
        shift
        cmd_export "$@"
        ;;
    get-flag)
        shift
        cmd_get_flag "$@"
        ;;
    list-models)
        cmd_list_models
        ;;
    list-claude-models)
        cmd_list_claude_models
        ;;
    list-providers)
        cmd_list_providers
        ;;
    get-defaults)
        shift
        cmd_get_defaults "$@"
        ;;
    get-runtime)
        cmd_get_runtime
        ;;
    get-codex)
        cmd_get_codex
        ;;
    get-gemini)
        cmd_get_gemini
        ;;
    list-grok-models)
        cmd_list_grok_models
        ;;
    get-grok)
        cmd_get_grok "${2:-}"
        ;;
    *)
        echo "Usage: $0 {validate|config-path|data-dir|export <model-id>|get-flag <feature>|list-models|list-claude-models|list-grok-models|list-providers|get-defaults <category>|get-runtime|get-codex|get-gemini|get-grok [<model>]}" >&2
        exit 2
        ;;
esac
