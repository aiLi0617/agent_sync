#!/usr/bin/env bash
# Installs git hooks that keep generated tool outputs in sync with .ai/src/.
#
# Which hooks depends on where the outputs live (`outputs:` in agent_sync.yaml):
#
#   committed — outputs travel through git, so a teammate needs nothing. The
#     risk is the editor forgetting to re-sync, so pre-commit re-syncs and
#     fails the commit when that changed a generated file, printing the paths
#     to stage. post-merge/post-checkout would only fight the incoming files.
#
#   local — every clone regenerates, so post-merge / post-checkout run a full
#     sync after `git pull` / `git checkout` (mtimes are reset on checkout, so
#     a staleness probe is unreliable there). `--pre-commit` adds a pre-commit
#     hook that runs `sync --if-stale`.
#
# Hooks land in the directory git actually reads (`git rev-parse --git-path
# hooks`), which honours core.hooksPath — so a repo using husky or lefthook
# gets instructions instead of a file nothing will run. Every hook is
# non-fatal about syncing itself: a failed sync warns but never blocks the git
# operation. Existing hook logic is preserved; the AgentSync block is appended
# once between markers and replaced in place on re-run.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
REPO_ROOT="${AGENTSYNC_REPO_ROOT:-$DEFAULT_REPO_ROOT}"

# shellcheck source=helpers/yaml.sh
source "$SCRIPT_DIR/helpers/yaml.sh"

INSTALL_PRE_COMMIT="false"
for arg in "$@"; do
    case "$arg" in
        --pre-commit) INSTALL_PRE_COMMIT="true" ;;
        --help|-h)
            echo "Usage: agentsync setup-hooks [--pre-commit]"
            echo ""
            echo "  Installs the git hooks that suit this project's outputs mode."
            echo ""
            echo "  committed: pre-commit re-syncs and fails the commit when a"
            echo "             generated file changed, so outputs never lag source."
            echo "  local:     post-merge and post-checkout run 'agentsync sync'"
            echo "             after pull/checkout."
            echo ""
            echo "  --pre-commit   In local mode, also install a pre-commit hook"
            echo "                 that runs 'agentsync sync --if-stale'."
            echo ""
            echo "  Set AGENTSYNC_SKIP_HOOKS=1 to make the installed hooks no-ops."
            exit 0
            ;;
        *)
            echo "Error: Unknown option: $arg" >&2
            echo "Usage: agentsync setup-hooks [--pre-commit]" >&2
            exit 2
            ;;
    esac
done

if [[ ! -d "$REPO_ROOT" ]]; then
    echo "Error: Repository root not found: $REPO_ROOT" >&2
    exit 1
fi

REPO_ROOT="$(cd "$REPO_ROOT" && pwd)"

if ! git -C "$REPO_ROOT" rev-parse --git-dir >/dev/null 2>&1; then
    echo "Error: Not a git repository: $REPO_ROOT" >&2
    exit 1
fi

# Echo <path> with its parent resolved physically, so the comparison below is
# not defeated by a symlinked ancestor (/tmp → /private/tmp on macOS).
_physical_path() {
    local path="$1" parent
    parent="$(cd -P "$(dirname "$path")" 2>/dev/null && pwd)" || { echo "$path"; return 0; }
    echo "$parent/$(basename "$path")"
}

# --git-path resolves relative to the repository, so anchor it there.
HOOKS_DIR="$(git -C "$REPO_ROOT" rev-parse --git-path hooks)"
case "$HOOKS_DIR" in
    /*) ;;
    *) HOOKS_DIR="$REPO_ROOT/$HOOKS_DIR" ;;
esac

GIT_DIR_ABS="$(git -C "$REPO_ROOT" rev-parse --absolute-git-dir)"
if [[ "$(_physical_path "$HOOKS_DIR")" != "$(_physical_path "$GIT_DIR_ABS/hooks")" ]]; then
    echo "This repository points core.hooksPath at another directory, so AgentSync"
    echo "will not write there:"
    echo ""
    echo "  $HOOKS_DIR"
    echo ""
    echo "A hook manager (husky, lefthook, pre-commit) most likely owns it. Add this"
    echo "to the hook it manages instead:"
    echo ""
    echo "  command -v agentsync >/dev/null 2>&1 && agentsync sync --if-stale || true"
    echo ""
    exit 0
fi

readonly BLOCK_START="# >>> AGENTSYNC AUTO SYNC START >>>"
readonly BLOCK_END="# <<< AGENTSYNC AUTO SYNC END <<<"

OUTPUTS_MODE="local"
for _config in "$REPO_ROOT/.ai/agent_sync.yaml" "$REPO_ROOT/agent_sync.yaml"; do
    [[ -f "$_config" ]] || continue
    _mode=$(parse_yaml_value "$_config" "outputs")
    _mode="${_mode//\"/}"
    case "$_mode" in
        committed|local) OUTPUTS_MODE="$_mode" ;;
        "")
            _gitignore=$(parse_yaml_value "$_config" "gitignore.update")
            [[ "$_gitignore" == "false" ]] && OUTPUTS_MODE="committed"
            ;;
    esac
    break
done

# Emit the POSIX-sh body run by a hook. $1 is the sync invocation (e.g.
# "sync" or "sync --if-stale"). Prefers the installed agentsync binary, then
# the in-repo engine (dogfooding / non-global installs). Always exits 0 so the
# git operation it hangs off of is never blocked by a sync failure.
emit_sync_body() {
    local sync_args="$1"
    cat <<EOF
[ -n "\${AGENTSYNC_SKIP_HOOKS:-}" ] && exit 0
if command -v agentsync >/dev/null 2>&1; then
    echo "AgentSync: syncing AI config..."
    agentsync $sync_args || echo "AgentSync: sync skipped — run 'agentsync sync' to see why." >&2
elif [ -f "lib/sync.sh" ]; then
    bash lib/sync.sh || true
elif [ -f "agent/lib/sync.sh" ]; then
    bash agent/lib/sync.sh || true
fi
EOF
}

# Committed outputs are only correct if they are committed *with* the source,
# so this body re-syncs and then blocks the commit when a generated file
# changed, naming the paths to stage. It never stages anything itself: the
# author reviews the diff like any other change.
emit_precommit_gate_body() {
    cat <<'EOF'
[ -n "${AGENTSYNC_SKIP_HOOKS:-}" ] && exit 0
if command -v agentsync >/dev/null 2>&1; then
    agentsync sync --if-stale || echo "AgentSync: sync skipped — run 'agentsync sync' to see why." >&2
fi
if [ -f ".ai/.sync-manifest" ]; then
    # Flag a generated file only when the commit would leave it behind: the
    # worktree differs from the index (second status column) or it is untracked.
    # Already-staged output is exactly what belongs in the commit. The manifest
    # is awk's first input, so the hook needs no temp file.
    _as_dirty=$(git status --porcelain --untracked-files=all \
        | awk -F'\t' '
            NR == FNR { keep[$1] = 1; next }
            {
                code = substr($0, 1, 2)
                path = substr($0, 4)
                if ((code == "??" || substr(code, 2, 1) != " ") && (path in keep))
                    print path
            }' ".ai/.sync-manifest" - || true)
    if [ -n "$_as_dirty" ]; then
        echo "AgentSync: generated files are out of date in this commit:" >&2
        printf '%s\n' "$_as_dirty" | sed 's/^/      /' >&2
        echo "" >&2
        echo "  They are regenerated from .ai/src/ and belong in the same commit." >&2
        echo "  Stage them (git add -A) and commit again." >&2
        echo "" >&2
        echo "  To commit without them: AGENTSYNC_SKIP_HOOKS=1 git commit ..." >&2
        exit 1
    fi
fi
EOF
}

append_agentsync_block() {
    local hook_file="$1"
    local body="$2"

    if grep -qF "$BLOCK_START" "$hook_file"; then
        echo "AgentSync hook already present in $(basename "$hook_file")."
        return 0
    fi

    {
        echo ""
        echo "$BLOCK_START"
        printf '%s\n' "$body"
        echo "$BLOCK_END"
    } >> "$hook_file"
}

install_hook() {
    local hook_name="$1"
    local body="$2"
    local hook_file="$HOOKS_DIR/$hook_name"

    if [[ ! -f "$hook_file" ]]; then
        {
            echo "#!/bin/sh"
            echo ""
        } > "$hook_file"
    fi

    append_agentsync_block "$hook_file" "$body"
    chmod +x "$hook_file"
    echo "Configured $hook_name hook."
}

if [[ "$OUTPUTS_MODE" == "committed" ]]; then
    install_hook "pre-commit" "$(emit_precommit_gate_body)"
    echo "Git hooks configured for committed outputs."
else
    install_hook "post-merge" "$(emit_sync_body "sync")"
    install_hook "post-checkout" "$(emit_sync_body "sync")"
    if [[ "$INSTALL_PRE_COMMIT" == "true" ]]; then
        install_hook "pre-commit" "$(emit_sync_body "sync --if-stale")"
    fi
    echo "Git hooks configured for local outputs."
fi
