#!/usr/bin/env bats
# Two-clone team workflow: a teammate's .ai/src/ change must sync cleanly after
# `git pull`. The sync manifest records what *this* clone generated, so it has
# to share the git status of the outputs it describes — a committed manifest
# beside ignored outputs makes every pull look like a manual edit.

load test_helper

setup() {
    TEST_PROJECT="$(mktemp -d "${TMPDIR:-/tmp}/agentsync_team.XXXXXX")"
    export AGENTSYNC_HOME="$REPO_ROOT"
    export GIT_AUTHOR_NAME=Test GIT_AUTHOR_EMAIL=test@test.com
    export GIT_COMMITTER_NAME=Test GIT_COMMITTER_EMAIL=test@test.com

    git init --quiet --bare "$TEST_PROJECT/origin.git"
    git clone --quiet "$TEST_PROJECT/origin.git" "$TEST_PROJECT/a" 2>/dev/null
    cd "$TEST_PROJECT/a"
    run_agentsync init --tools claude --yes >/dev/null 2>&1
    run_agentsync sync >/dev/null 2>&1
    git add -A
    git commit --quiet -m "init agentsync"
    git push --quiet -u origin HEAD 2>/dev/null

    git clone --quiet "$TEST_PROJECT/origin.git" "$TEST_PROJECT/b" 2>/dev/null
    cd "$TEST_PROJECT/b"
    run_agentsync sync >/dev/null 2>&1
}

teardown() {
    teardown_test_project
}

# Clone a edits a rule, syncs, and pushes.
push_rule_edit() {
    cd "$TEST_PROJECT/a"
    printf '\n- Team rule added by a.\n' >> .ai/src/rules/core.md
    run_agentsync sync >/dev/null 2>&1
    git add -A
    git commit --quiet -m "rules: add team rule"
    git push --quiet 2>/dev/null
}

@test "team: sync manifest is gitignored alongside the outputs it describes" {
    cd "$TEST_PROJECT/a"
    git check-ignore -q .ai/.sync-manifest
    ! git ls-files --error-unmatch .ai/.sync-manifest >/dev/null 2>&1
}

@test "team: a rule edit commits only the source, not the manifest" {
    push_rule_edit
    cd "$TEST_PROJECT/a"
    git show --stat --format= HEAD | grep -q "rules/core.md"
    ! git show --stat --format= HEAD | grep -q "sync-manifest"
}

@test "team: teammate's rule edit syncs after git pull without a drift refusal" {
    push_rule_edit
    cd "$TEST_PROJECT/b"
    git pull --quiet 2>/dev/null
    run run_agentsync sync
    [ "$status" -eq 0 ]
    grep -q "Team rule added by a" .claude/rules/core.md
}

@test "team: manual edit of a generated file is still refused after a pull" {
    push_rule_edit
    cd "$TEST_PROJECT/b"
    git pull --quiet 2>/dev/null
    run_agentsync sync >/dev/null 2>&1
    printf '\n# hand edit\n' >> .claude/rules/core.md
    run run_agentsync sync
    [ "$status" -ne 0 ]
    [[ "$output" == *"Manual edits detected"* ]]
}
