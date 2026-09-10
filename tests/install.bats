#!/usr/bin/env bats
# install.sh and `update <version>` against a local clone of this repository.
# Every path the installer touches is redirected into the test project so the
# developer's ~/.agentsync, PATH symlink, and shell rc are never modified.

load test_helper

setup() {
    setup_test_project
    export HOME="$TEST_PROJECT/home"
    mkdir -p "$HOME"
    touch "$HOME/.zshrc"
    export AGENTSYNC_REPO_URL="$REPO_ROOT"
    export AGENTSYNC_INSTALL_DIR="$TEST_PROJECT/engine"
    export AGENTSYNC_BIN_DIR="$TEST_PROJECT/bin"
    # `update` re-links whichever agentsync is on PATH; keep it the test one.
    export PATH="$TEST_PROJECT/bin:$PATH"
}

teardown() {
    teardown_test_project
}

@test "install: AGENTSYNC_VERSION pins the engine to that release tag" {
    run env AGENTSYNC_VERSION=0.33.5 bash "$REPO_ROOT/install.sh"
    [ "$status" -eq 0 ]
    [ "$(cat "$TEST_PROJECT/engine/VERSION")" = "0.33.5" ]
    [ -e "$TEST_PROJECT/bin/agentsync" ]
    grep -q "AGENTSYNC_HOME" "$HOME/.zshrc"
}

@test "install: an unknown AGENTSYNC_VERSION fails clearly" {
    run env AGENTSYNC_VERSION=999.0.0 bash "$REPO_ROOT/install.sh"
    [ "$status" -ne 0 ]
    [[ "$output" == *"999.0.0"* ]]
}

@test "install: re-running with a different pin moves an existing install" {
    env AGENTSYNC_VERSION=0.33.5 bash "$REPO_ROOT/install.sh" >/dev/null
    run env AGENTSYNC_VERSION=0.33.4 bash "$REPO_ROOT/install.sh"
    [ "$status" -eq 0 ]
    [ "$(cat "$TEST_PROJECT/engine/VERSION")" = "0.33.4" ]
}

@test "update <version>: pins an installed engine to that release" {
    env AGENTSYNC_VERSION=0.33.5 bash "$REPO_ROOT/install.sh" >/dev/null
    run env AGENTSYNC_HOME="$TEST_PROJECT/engine" bash "$AGENTSYNC_BIN" update 0.33.4
    [ "$status" -eq 0 ]
    [ "$(cat "$TEST_PROJECT/engine/VERSION")" = "0.33.4" ]
    [[ "$output" == *"0.33.4"* ]]
}

@test "update <version>: rejects a version that is not a release tag" {
    env AGENTSYNC_VERSION=0.33.5 bash "$REPO_ROOT/install.sh" >/dev/null
    run env AGENTSYNC_HOME="$TEST_PROJECT/engine" bash "$AGENTSYNC_BIN" update 999.0.0
    [ "$status" -ne 0 ]
    [[ "$output" == *"999.0.0"* ]]
    [ "$(cat "$TEST_PROJECT/engine/VERSION")" = "0.33.5" ]
}
