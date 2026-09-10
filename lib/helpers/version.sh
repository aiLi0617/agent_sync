#!/usr/bin/env bash
# Engine version and the project's agentsync_version pin. Requires yaml.sh.

# Echo the engine version from the VERSION file beside <lib_dir>; "0.0.0-dev" when absent.
engine_version() {
    local lib_dir="$1"
    local file="$lib_dir/../VERSION" v=""
    if [[ -f "$file" ]]; then
        read -r v < "$file" || true
    fi
    echo "${v:-0.0.0-dev}"
}

# Echo the agentsync_version pinned in <config>, or nothing when unpinned.
pinned_version() {
    local config="$1"
    [[ -f "$config" ]] || return 0
    local v
    v=$(parse_yaml_value "$config" "agentsync_version")
    echo "${v//\"/}"
}

# Print the two ways out of a pin/engine mismatch.
version_pin_mismatch_hint() {
    local pinned="$1" engine="$2"
    echo "  • Match the pin:  agentsync update $pinned"
    echo "  • Or move it:     agentsync upgrade-config   (re-pins to $engine; re-sync and commit the outputs)"
}
