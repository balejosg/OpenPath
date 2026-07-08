#!/usr/bin/env bats
# Performance Benchmark Tests for OpenPath
# Tests parsing and generation performance with large datasets

load 'test_helper'

setup() {
    # Create temp directory for test files
    TEST_DIR=$(mktemp -d)
    export CONFIG_DIR="$TEST_DIR"
    export VAR_STATE_DIR="$TEST_DIR"
    export ETC_CONFIG_DIR="$TEST_DIR/etc"
    export LOG_FILE="$TEST_DIR/test.log"
    export DNSMASQ_CONF="$TEST_DIR/openpath.conf"
    mkdir -p "$ETC_CONFIG_DIR"
    touch "$LOG_FILE"

    # Source required libraries (LOG_FILE export is respected)
    source "$BATS_TEST_DIRNAME/../linux/lib/common.sh"
    source "$BATS_TEST_DIRNAME/../linux/lib/dns.sh"
}

teardown() {
    rm -rf "$TEST_DIR"
}

# =============================================================================
# Whitelist Parsing Performance
# =============================================================================

@test "parse 1000 domains under 3 seconds" {
    WHITELIST_FILE="$TEST_DIR/whitelist.txt"

    # Generate 1000 domains
    for i in $(seq 1 1000); do
        echo "domain${i}.example.com"
    done > "$WHITELIST_FILE"

    # Time the parsing
    start_time=$(date +%s%N)
    parse_whitelist_sections "$WHITELIST_FILE"
    end_time=$(date +%s%N)

    # Calculate elapsed time in milliseconds
    elapsed_ms=$(( (end_time - start_time) / 1000000 ))

    echo "Parsed 1000 domains in ${elapsed_ms}ms"
    # CI runners can be noisy; keep a stable threshold.
    [ "$elapsed_ms" -lt 3000 ]
    [ "${#WHITELIST_DOMAINS[@]}" -ge 1000 ]
    [[ " ${WHITELIST_DOMAINS[*]} " == *" domain1.example.com "* ]]
    [[ " ${WHITELIST_DOMAINS[*]} " == *" domain1000.example.com "* ]]
}

@test "parse 5000 domains under 15 seconds" {
    WHITELIST_FILE="$TEST_DIR/whitelist.txt"

    # Generate 5000 domains
    for i in $(seq 1 5000); do
        echo "domain${i}.example.com"
    done > "$WHITELIST_FILE"

    start_time=$(date +%s%N)
    parse_whitelist_sections "$WHITELIST_FILE"
    end_time=$(date +%s%N)

    elapsed_ms=$(( (end_time - start_time) / 1000000 ))

    echo "Parsed 5000 domains in ${elapsed_ms}ms"
    # CI runners can be noisy; keep a stable threshold.
    [ "$elapsed_ms" -lt 15000 ]
    [ "${#WHITELIST_DOMAINS[@]}" -ge 5000 ]
    [[ " ${WHITELIST_DOMAINS[*]} " == *" domain1.example.com "* ]]
    [[ " ${WHITELIST_DOMAINS[*]} " == *" domain5000.example.com "* ]]
}

# =============================================================================
# Domain Validation Performance
# =============================================================================

@test "validate 1000 domains under 12 seconds" {
    start_time=$(date +%s%N)

    for i in $(seq 1 1000); do
        validate_domain "subdomain${i}.example.com"
    done

    end_time=$(date +%s%N)
    elapsed_ms=$(( (end_time - start_time) / 1000000 ))

    echo "Validated 1000 domains in ${elapsed_ms}ms"
    # CI runners can be noisy; keep a stable threshold.
    [ "$elapsed_ms" -lt 12000 ]
}

@test "validate complex domains efficiently" {
    # Complex domains with many subdomains
    domains=(
        "sub1.sub2.sub3.example.com"
        "very-long-subdomain-name.another-long-part.domain.co.uk"
        "a.b.c.d.e.f.g.h.i.j.example.org"
    )

    start_time=$(date +%s%N)

    for _ in $(seq 1 100); do
        for domain in "${domains[@]}"; do
            validate_domain "$domain"
        done
    done

    end_time=$(date +%s%N)
    elapsed_ms=$(( (end_time - start_time) / 1000000 ))

    echo "Validated 300 complex domains in ${elapsed_ms}ms"
    # CI runners can be noisy; keep a stable threshold.
    [ "$elapsed_ms" -lt 7000 ]
}

# =============================================================================
# Hash Computation Performance
# =============================================================================

@test "sha256sum on 1MB file under 100ms" {
    TEST_FILE="$TEST_DIR/large.txt"

    # Create 1MB file
    dd if=/dev/urandom of="$TEST_FILE" bs=1024 count=1024 2>/dev/null

    start_time=$(date +%s%N)
    sha256sum "$TEST_FILE" > /dev/null
    end_time=$(date +%s%N)

    elapsed_ms=$(( (end_time - start_time) / 1000000 ))

    echo "SHA256 of 1MB in ${elapsed_ms}ms"
    [ "$elapsed_ms" -lt 100 ]
}

@test "hash computation fast enough for change detection" {
    TEST_FILE="$TEST_DIR/test.txt"
    echo "test content for hash comparison" > "$TEST_FILE"

    # Time md5sum
    start_time=$(date +%s%N)
    for _ in $(seq 1 100); do
        md5sum "$TEST_FILE" > /dev/null
    done
    md5_time=$(( ($(date +%s%N) - start_time) / 1000000 ))

    # Time sha256sum
    start_time=$(date +%s%N)
    for _ in $(seq 1 100); do
        sha256sum "$TEST_FILE" > /dev/null
    done
    sha256_time=$(( ($(date +%s%N) - start_time) / 1000000 ))

    echo "md5sum 100x: ${md5_time}ms, sha256sum 100x: ${sha256_time}ms"
    # Process startup dominates this microbenchmark on loaded runners.
    # Keeping 100 iterations under 1s preserves sub-10ms hashing for the
    # single-file change detection paths used in practice.
    [ "$md5_time" -lt 1000 ]
    [ "$sha256_time" -lt 1000 ]
}

# =============================================================================
# dnsmasq Config Generation Performance
# =============================================================================

@test "generate dnsmasq config for 1000 domains under 60 seconds" {
    # Setup whitelist domains
    WHITELIST_DOMAINS=()
    for i in $(seq 1 1000); do
        WHITELIST_DOMAINS+=("domain${i}.example.com")
    done
    BLOCKED_SUBDOMAINS=()
    PRIMARY_DNS="8.8.8.8"

    start_time=$(date +%s%N)
    generate_dnsmasq_config
    end_time=$(date +%s%N)

    elapsed_ms=$(( (end_time - start_time) / 1000000 ))

    echo "Generated config for 1000 domains in ${elapsed_ms}ms"
    # Bash-with-per-domain-validation config generation for 1000 domains runs
    # ~4s on a dev machine but ~30s on a throttled GitHub-hosted runner (measured
    # 30462ms, right at the old 30s edge). Doubled to 60s so normal CI-runner
    # noise cannot flake it while still catching a genuine >2x perf regression.
    [ "$elapsed_ms" -lt 60000 ]
    [ -f "$DNSMASQ_CONF" ]

    # Verify config has correct number of server= lines
    server_lines=$(grep -c "^server=/" "$DNSMASQ_CONF" || echo "0")
    # Should have 1000 + essential domains
    [ "$server_lines" -gt 1000 ]
}

# =============================================================================
# Memory Usage (Basic)
# =============================================================================

@test "array operations do not cause excessive memory growth" {
    # This is a basic test - real memory testing would need more tooling
    WHITELIST_DOMAINS=()

    # Add 10000 domains
    for i in $(seq 1 10000); do
        WHITELIST_DOMAINS+=("domain${i}.example.com")
    done

    # Verify we can access all elements
    [ "${#WHITELIST_DOMAINS[@]}" -eq 10000 ]
    [ "${WHITELIST_DOMAINS[0]}" = "domain1.example.com" ]
    [ "${WHITELIST_DOMAINS[9999]}" = "domain10000.example.com" ]
}
