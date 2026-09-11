#!/usr/bin/env bash
# Project format revision — a monotonic counter bumped only when a project
# needs a migration step, kept separate from the release version so a patch
# release never asks anyone to migrate. Requires yaml.sh.
#
# `format:` in agent_sync.yaml records which migrations a project has been
# walked through. Only `init` (nothing to migrate) and `migrate --apply` write
# it: anything else writing it would silence a migration that still applies.

# Echo the revision this engine expects; 1 when the FORMAT file is missing.
engine_format() {
    local lib_dir="$1"
    local file="$lib_dir/../FORMAT" v=""
    if [[ -f "$file" ]]; then
        read -r v < "$file" || true
    fi
    case "$v" in
        ''|*[!0-9]*) echo 1 ;;
        *)           echo "$v" ;;
    esac
}

# Echo the revision a project has been migrated to; 1 when the key is absent.
project_format() {
    local config="$1" v=""
    if [[ -f "$config" ]]; then
        v=$(parse_yaml_value "$config" "format")
    fi
    v="${v//\"/}"
    case "$v" in
        ''|*[!0-9]*) echo 1 ;;
        *)           echo "$v" ;;
    esac
}

# Print one line per migration the project has not been walked through.
# Usage: format_pending_notes <project_format> <engine_format>
format_pending_notes() {
    local from="$1" to="$2"
    local step=$((from + 1))
    while [[ $step -le $to ]]; do
        case "$step" in
            2)
                echo "r2  The agentsync skill is engine-owned now. A copy under .ai/src/skills/agentsync/ shadows it, so engine upgrades never reach your agents."
                ;;
            *)
                echo "r$step  See CHANGELOG.md for what changed."
                ;;
        esac
        step=$((step + 1))
    done
}

# Locate the project config for <project_dir>; echoes nothing when absent.
format_config_path() {
    local project_dir="$1"
    if [[ -f "$project_dir/.ai/agent_sync.yaml" ]]; then
        echo "$project_dir/.ai/agent_sync.yaml"
    elif [[ -f "$project_dir/agent_sync.yaml" ]]; then
        echo "$project_dir/agent_sync.yaml"
    fi
}
