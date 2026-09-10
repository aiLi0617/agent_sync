#!/usr/bin/env bats
# Tests for the `outputs:` mode in agent_sync.yaml — committed (generated files
# and the manifest stay visible to git) vs local (both are gitignored).

load test_helper

setup() {
    setup_test_project
}

teardown() {
    teardown_test_project
}

# Rewrite the outputs: line in .ai/agent_sync.yaml (write-then-mv, no sed -i).
set_outputs_mode() {
    local mode="$1"
    sed "s/^outputs: .*/outputs: $mode/" .ai/agent_sync.yaml > .ai/agent_sync.yaml.tmp
    mv .ai/agent_sync.yaml.tmp .ai/agent_sync.yaml
}

drop_outputs_key() {
    grep -v "^outputs:" .ai/agent_sync.yaml > .ai/agent_sync.yaml.tmp
    mv .ai/agent_sync.yaml.tmp .ai/agent_sync.yaml
}

@test "outputs: init defaults new projects to committed" {
    run_agentsync init --tools claude --yes >/dev/null 2>&1
    grep -q "^outputs: committed" .ai/agent_sync.yaml
}

@test "outputs: init --outputs local writes local" {
    run_agentsync init --tools claude --yes --outputs local >/dev/null 2>&1
    grep -q "^outputs: local" .ai/agent_sync.yaml
}

@test "outputs: init rejects an unknown mode" {
    run run_agentsync init --tools claude --yes --outputs bogus
    [ "$status" -ne 0 ]
    [[ "$output" == *"committed"* ]]
    [[ "$output" == *"local"* ]]
}

@test "outputs: committed sync leaves generated files and the manifest visible to git" {
    run_agentsync init --tools claude --yes >/dev/null 2>&1
    run_agentsync sync >/dev/null 2>&1
    [ -f CLAUDE.md ]
    ! git check-ignore -q CLAUDE.md
    ! git check-ignore -q .ai/.sync-manifest
    ! grep -qs "AI SYNC GENERATED START" .gitignore
}

@test "outputs: local sync gitignores generated files and the manifest" {
    run_agentsync init --tools claude --yes --outputs local >/dev/null 2>&1
    run_agentsync sync >/dev/null 2>&1
    git check-ignore -q CLAUDE.md
    git check-ignore -q .ai/.sync-manifest
}

@test "outputs: switching local to committed empties the managed block" {
    run_agentsync init --tools claude --yes --outputs local >/dev/null 2>&1
    run_agentsync sync >/dev/null 2>&1
    git check-ignore -q CLAUDE.md

    set_outputs_mode committed
    run_agentsync sync >/dev/null 2>&1
    ! git check-ignore -q CLAUDE.md
    ! git check-ignore -q .ai/.sync-manifest
    grep -q "AI SYNC GENERATED START" .gitignore
}

@test "outputs: a missing key keeps the pre-existing local behaviour" {
    run_agentsync init --tools claude --yes >/dev/null 2>&1
    drop_outputs_key
    run_agentsync sync >/dev/null 2>&1
    git check-ignore -q CLAUDE.md
    git check-ignore -q .ai/.sync-manifest
}

@test "outputs: a missing key with gitignore.update false means committed" {
    run_agentsync init --tools claude --yes >/dev/null 2>&1
    drop_outputs_key
    sed "s/^  update: true/  update: false/" .ai/agent_sync.yaml > .ai/agent_sync.yaml.tmp
    mv .ai/agent_sync.yaml.tmp .ai/agent_sync.yaml
    printf 'keep-me\n' > .gitignore
    run_agentsync sync >/dev/null 2>&1
    [ "$(cat .gitignore)" = "keep-me" ]
    ! git check-ignore -q CLAUDE.md
}

@test "outputs: an unknown value fails sync before writing anything" {
    run_agentsync init --tools claude --yes >/dev/null 2>&1
    set_outputs_mode bogus
    run run_agentsync sync
    [ "$status" -ne 0 ]
    [[ "$output" == *"outputs"* ]]
    [ ! -f CLAUDE.md ]
}

@test "outputs: committed mode still gitignores profile config homes" {
    run_agentsync init --tools claude --yes >/dev/null 2>&1
    run_agentsync profile add hub --tools claude >/dev/null 2>&1
    run_agentsync sync >/dev/null 2>&1
    grep -q "claude-hub" .gitignore
    ! git check-ignore -q CLAUDE.md
}
