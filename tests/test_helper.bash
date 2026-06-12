#!/bin/bash
################################################################################
# test_helper.bash - Funciones comunes para tests bats
################################################################################

# Directorio de tests
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$TEST_DIR/.." && pwd)"

# Directorio temporal para tests
TEST_TMP_DIR=""

# Setup antes de cada test
setup() {
    # Crear directorio temporal único para este test
    TEST_TMP_DIR=$(mktemp -d)
    export CONFIG_DIR="$TEST_TMP_DIR/config"
    export INSTALL_DIR="$TEST_TMP_DIR/install"
    mkdir -p "$CONFIG_DIR"
    mkdir -p "$INSTALL_DIR/lib" "$INSTALL_DIR/libexec"
    
    # Copiar librerías al directorio de test
    cp "$PROJECT_DIR/linux/lib/"*.sh "$INSTALL_DIR/lib/" 2>/dev/null || true
    cp "$PROJECT_DIR/linux/libexec/"* "$INSTALL_DIR/libexec/" 2>/dev/null || true
}

# Teardown después de cada test
teardown() {
    if [ -n "$TEST_TMP_DIR" ] && [ -d "$TEST_TMP_DIR" ]; then
        rm -rf "$TEST_TMP_DIR"
    fi
}

# Helper: crear whitelist de prueba
create_test_whitelist() {
    local file="${1:-$TEST_TMP_DIR/whitelist.txt}"
    cat > "$file" << 'EOF'
## WHITELIST
google.com
github.com
example.org

## BLOCKED-SUBDOMAINS
ads.google.com
tracking.example.org

## BLOCKED-PATHS
example.org/ads
google.com/tracking
EOF
    echo "$file"
}

# Helper: crear whitelist desactivada
create_disabled_whitelist() {
    local file="${1:-$TEST_TMP_DIR/whitelist.txt}"
    cat > "$file" << 'EOF'
#DESACTIVADO

## WHITELIST
google.com
EOF
    echo "$file"
}

# Helper: mock de un comando
mock_command() {
    local cmd="$1"
    local output="$2"
    local exit_code="${3:-0}"
    
    eval "$cmd() { echo '$output'; return $exit_code; }"
    export -f "$cmd"
}

# Helper: load non-empty, non-comment lines from shared contract fixtures
load_contract_fixture_lines() {
    local fixture_file="$1"
    local fixture_path="$PROJECT_DIR/tests/contracts/$fixture_file"

    while IFS= read -r line || [ -n "$line" ]; do
        line="${line%$'\r'}"
        [[ -z "${line//[[:space:]]/}" ]] && continue
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        printf '%s\n' "$line"
    done < "$fixture_path"
}

# Helper: split comma-separated values into normalized lines
csv_to_lines() {
    local csv="$1"
    local entry
    local values=()

    IFS=',' read -r -a values <<< "$csv"
    for entry in "${values[@]}"; do
        entry="${entry//[[:space:]]/}"
        [ -n "$entry" ] && printf '%s\n' "$entry"
    done
}

# Helper: create the standard tmp dir layout used by most linux agent tests.
# Sets TEST_TMP_DIR, CONFIG_DIR, INSTALL_DIR and copies linux/lib/*.sh into
# INSTALL_DIR/lib. Call from within a local setup() before any file-specific work.
setup_std_lib_layout() {
    TEST_TMP_DIR=$(mktemp -d)
    export CONFIG_DIR="$TEST_TMP_DIR/config"
    export INSTALL_DIR="$TEST_TMP_DIR/install"
    mkdir -p "$CONFIG_DIR"
    mkdir -p "$INSTALL_DIR/lib"
    cp "$PROJECT_DIR/linux/lib/"*.sh "$INSTALL_DIR/lib/" 2>/dev/null || true
}

# Helper: install a minimal log() mock into the current shell and export it so
# subprocesses see it. Echoes the message to stdout so tests can still capture
# it, without the timestamps and file writes of the real logger.
setup_mock_log() {
    log() { echo "$1"; }
    export -f log
}
