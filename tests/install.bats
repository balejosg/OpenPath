#!/usr/bin/env bats
################################################################################
# install.bats - Tests for linux/install.sh
################################################################################

load 'test_helper'

@test "install.sh runs preflight validation by default" {
    run grep -n "run_pre_install_validation" "$PROJECT_DIR/linux/install.sh"
    [ "$status" -eq 0 ]

    run grep -n "SKIP_PREFLIGHT" "$PROJECT_DIR/linux/install.sh"
    [ "$status" -eq 0 ]
}

@test "install.sh supports --skip-preflight option" {
    run grep -n -- "--skip-preflight" "$PROJECT_DIR/linux/install.sh"
    [ "$status" -eq 0 ]
}

@test "linux installers share the generic progress helper" {
    run test -f "$PROJECT_DIR/linux/lib/progress.sh"
    [ "$status" -eq 0 ]

    run grep -n 'source "$INSTALLER_SOURCE_DIR/lib/progress.sh"' "$PROJECT_DIR/linux/install.sh"
    [ "$status" -eq 0 ]

    run grep -n 'source "$SCRIPT_DIR/lib/progress.sh"' "$PROJECT_DIR/linux/quick-install.sh"
    [ "$status" -eq 0 ]

    run grep -n 'openpath_show_progress' "$PROJECT_DIR/linux/install.sh"
    [ "$status" -eq 0 ]

    run grep -n 'openpath_show_progress' "$PROJECT_DIR/linux/quick-install.sh"
    [ "$status" -eq 0 ]

}

@test "install.sh supports --skip-firefox option" {
    run grep -n -- "--skip-firefox" "$PROJECT_DIR/linux/install.sh"
    [ "$status" -eq 0 ]
}

@test "install.sh hardens sensitive config permissions" {
    run grep -n "persist_openpath_whitelist_url" "$PROJECT_DIR/linux/lib/install-core-steps.sh"
    [ "$status" -eq 0 ]

    run grep -n 'chmod "\$mode" "\$temp_file"' "$PROJECT_DIR/linux/lib/common-config-persistence.sh"
    [ "$status" -eq 0 ]

    run grep -n 'persist_openpath_health_api_config' "$PROJECT_DIR/linux/lib/install-core-steps.sh"
    [ "$status" -eq 0 ]

    run grep -n 'write_openpath_config_file "\$HEALTH_API_SECRET_CONF" "\$health_api_secret" 600' "$PROJECT_DIR/linux/lib/common-config-persistence.sh"
    [ "$status" -eq 0 ]
}

@test "linux installers and runtime reuse shared config persistence helpers" {
    run grep -n "persist_openpath_whitelist_url" "$PROJECT_DIR/linux/lib/install-core-steps.sh"
    [ "$status" -eq 0 ]

    run grep -n "persist_openpath_health_api_config" "$PROJECT_DIR/linux/lib/install-core-steps.sh"
    [ "$status" -eq 0 ]

    run grep -n "persist_openpath_whitelist_url" "$PROJECT_DIR/linux/debian-package/DEBIAN/postinst"
    [ "$status" -eq 0 ]

    run grep -n "persist_openpath_health_api_config" "$PROJECT_DIR/linux/debian-package/DEBIAN/postinst"
    [ "$status" -eq 0 ]

    run grep -n "persist_openpath_enrollment_state" "$PROJECT_DIR/linux/lib/runtime-cli-commands.sh"
    [ "$status" -eq 0 ]

    run grep -n 'source "\$INSTALL_DIR/lib/runtime-cli.sh"' "$PROJECT_DIR/linux/scripts/runtime/openpath-cmd.sh"
    [ "$status" -eq 0 ]
}

@test "linux installer composes shared install helper modules" {
    run grep -nF 'source "$INSTALLER_SOURCE_DIR/lib/install-helpers.sh"' "$PROJECT_DIR/linux/install.sh"
    [ "$status" -eq 0 ]

    run grep -nF 'source "$INSTALLER_SOURCE_DIR/lib/install-core-steps.sh"' "$PROJECT_DIR/linux/install.sh"
    [ "$status" -eq 0 ]

    run grep -nF 'source "$INSTALLER_SOURCE_DIR/lib/install-runtime-steps.sh"' "$PROJECT_DIR/linux/install.sh"
    [ "$status" -eq 0 ]

    run grep -nF 'source "$INSTALL_DIR/lib/runtime-cli-system.sh"' "$PROJECT_DIR/linux/lib/runtime-cli.sh"
    [ "$status" -eq 0 ]

    run grep -nF 'source "$INSTALL_DIR/lib/runtime-cli-commands.sh"' "$PROJECT_DIR/linux/lib/runtime-cli.sh"
    [ "$status" -eq 0 ]

    run grep -nF 'source "$(dirname "${BASH_SOURCE[0]}")/common-connectivity.sh"' "$PROJECT_DIR/linux/lib/common.sh"
    [ "$status" -eq 0 ]

    run grep -nF 'source "$(dirname "${BASH_SOURCE[0]}")/common-registration.sh"' "$PROJECT_DIR/linux/lib/common.sh"
    [ "$status" -eq 0 ]

    run grep -nF 'source "$(dirname "${BASH_SOURCE[0]}")/common-locking.sh"' "$PROJECT_DIR/linux/lib/common.sh"
    [ "$status" -eq 0 ]

    run grep -nF 'source "$(dirname "${BASH_SOURCE[0]}")/common-config-persistence.sh"' "$PROJECT_DIR/linux/lib/common.sh"
    [ "$status" -eq 0 ]

    run grep -nF 'source "$(dirname "${BASH_SOURCE[0]}")/common-protected-domains.sh"' "$PROJECT_DIR/linux/lib/common.sh"
    [ "$status" -eq 0 ]
}

@test "install.sh allows installer contract runs without a whitelist URL" {
    run grep -nF 'if [ -n "$WHITELIST_URL" ]; then' "$PROJECT_DIR/linux/lib/install-core-steps.sh"
    [ "$status" -eq 0 ]

    run grep -nF 'Whitelist URL not configured yet' "$PROJECT_DIR/linux/lib/install-core-steps.sh"
    [ "$status" -eq 0 ]
}

@test "apt bootstrap script exists" {
    run test -f "$PROJECT_DIR/linux/scripts/build/apt-bootstrap.sh"
    [ "$status" -eq 0 ]
}

@test "apt bootstrap script runs classroom setup wizard" {
    run grep -n "openpath setup" "$PROJECT_DIR/linux/scripts/build/apt-bootstrap.sh"
    [ "$status" -eq 0 ]
}

@test "installers detect upstream DNS before stopping systemd-resolved" {
    local install_file="$PROJECT_DIR/linux/install.sh"
    local postinst_file="$PROJECT_DIR/linux/debian-package/DEBIAN/postinst"

    local install_detect_line
    local install_free_line
    install_detect_line=$(grep -n 'Detecting primary DNS" step_detect_dns' "$install_file" | cut -d: -f1)
    install_free_line=$(grep -n 'Releasing port 53" step_free_port_53' "$install_file" | cut -d: -f1)

    local postinst_detect_line
    local postinst_free_line
    postinst_detect_line=$(grep -n "Detecting primary DNS" "$postinst_file" | head -1 | cut -d: -f1)
    postinst_free_line=$(grep -n "Releasing port 53" "$postinst_file" | head -1 | cut -d: -f1)

    [ -n "$install_detect_line" ]
    [ -n "$install_free_line" ]
    [ -n "$postinst_detect_line" ]
    [ -n "$postinst_free_line" ]
    [ "$install_detect_line" -lt "$install_free_line" ]
    [ "$postinst_detect_line" -lt "$postinst_free_line" ]
}

@test "free_port_53 stops distro dnsmasq before disabling systemd-resolved" {
    local helper_script="$TEST_TMP_DIR/run-free-port-53.sh"
    local state_dir="$TEST_TMP_DIR/free-port-53-state"

    mkdir -p "$state_dir"

    cat > "$helper_script" <<'EOF'
#!/bin/bash
set -euo pipefail

project_dir="$1"
state_dir="$2"
log_file="$state_dir/calls.log"
: > "$log_file"

log() {
    printf 'log %s\n' "$*" >> "$log_file"
}

systemctl() {
    printf 'systemctl %s\n' "$*" >> "$log_file"
    return 0
}

ss() {
    return 0
}

sleep() {
    printf 'sleep %s\n' "$*" >> "$log_file"
}

source "$project_dir/linux/lib/dns-runtime.sh"
free_port_53

dnsmasq_stop_line="$(grep -n '^systemctl stop dnsmasq$' "$log_file" | head -1 | cut -d: -f1)"
resolved_stop_line="$(grep -n '^systemctl stop systemd-resolved.socket$' "$log_file" | head -1 | cut -d: -f1)"

cat "$log_file"

[ -n "$dnsmasq_stop_line" ]
[ -n "$resolved_stop_line" ]
[ "$dnsmasq_stop_line" -lt "$resolved_stop_line" ]
EOF
    chmod +x "$helper_script"

    run "$helper_script" "$PROJECT_DIR" "$state_dir"

    [ "$status" -eq 0 ]
}

@test "apt bootstrap script keeps browser setup gated behind request setup validation" {
    run grep -n "OPENPATH_BROWSER_SETUP_SCRIPT" "$PROJECT_DIR/linux/scripts/build/apt-bootstrap.sh"
    [ "$status" -eq 0 ]

    run grep -n "openpath-browser-setup.sh" "$PROJECT_DIR/linux/scripts/build/apt-bootstrap.sh"
    [ "$status" -eq 0 ]

    run grep -n "require_bootstrap_request_setup_complete" "$PROJECT_DIR/linux/scripts/build/apt-bootstrap.sh"
    [ "$status" -eq 0 ]
}

@test "apt bootstrap supports enrollment token flags" {
    run grep -n -- "--classroom-id" "$PROJECT_DIR/linux/scripts/build/apt-bootstrap.sh"
    [ "$status" -eq 0 ]

    run grep -n -- "--enrollment-token" "$PROJECT_DIR/linux/scripts/build/apt-bootstrap.sh"
    [ "$status" -eq 0 ]
}

@test "apt bootstrap supports pinning an explicit package version" {
    run grep -n -- "--package-version" "$PROJECT_DIR/linux/scripts/build/apt-bootstrap.sh"
    [ "$status" -eq 0 ]
}

@test "apt bootstrap preserves HTTPS hardening while allowing explicit local repo overrides" {
    run grep -n 'if \[\[ "\$APT_SETUP_URL" == https://\* \]\]; then' "$PROJECT_DIR/linux/scripts/build/apt-bootstrap.sh"
    [ "$status" -eq 0 ]

    run grep -n -- "--proto '=https' --tlsv1.2" "$PROJECT_DIR/linux/scripts/build/apt-bootstrap.sh"
    [ "$status" -eq 0 ]

    run grep -n 'curl -fsSL "\$APT_SETUP_URL" -o "\$setup_script"' "$PROJECT_DIR/linux/scripts/build/apt-bootstrap.sh"
    [ "$status" -eq 0 ]
}

@test "apt scripts support overriding the repository URL for runtime contracts" {
    run grep -n 'OPENPATH_APT_REPO_URL' "$PROJECT_DIR/linux/scripts/build/apt-setup.sh"
    [ "$status" -eq 0 ]

    run grep -n 'OPENPATH_APT_REPO_URL' "$PROJECT_DIR/linux/scripts/build/apt-bootstrap.sh"
    [ "$status" -eq 0 ]
}

@test "apt setup installs the keyring idempotently" {
    run grep -n 'gpg --batch --yes --dearmor -o "\$KEYRING_PATH"' "$PROJECT_DIR/linux/scripts/build/apt-setup.sh"
    [ "$status" -eq 0 ]
}

@test "linux installer contracts runner exposes installer-only mode" {
    run grep -n -- '--installer-only' "$PROJECT_DIR/tests/e2e/ci/run-linux-e2e.sh"
    [ "$status" -eq 0 ]

    run grep -n 'OPENPATH_INSTALLER_CONTRACT_MODE' "$PROJECT_DIR/tests/e2e/docker-e2e-runner.sh"
    [ "$status" -eq 0 ]

    run grep -n '/proc/1/environ' "$PROJECT_DIR/tests/e2e/docker-e2e-runner.sh"
    [ "$status" -eq 0 ]

    run grep -n '/usr/local/lib/openpath/uninstall.sh --auto-yes' "$PROJECT_DIR/tests/e2e/ci/run-linux-e2e.sh"
    [ "$status" -eq 0 ]
}

@test "linux installers ship the browser setup helper" {
    run grep -n 'openpath-browser-setup.sh' "$PROJECT_DIR/linux/scripts/build/build-deb.sh"
    [ "$status" -eq 0 ]

    run grep -n 'openpath-browser-setup.sh' "$PROJECT_DIR/linux/lib/install-core-steps.sh"
    [ "$status" -eq 0 ]
}

@test "package scripts expose linux installer contract commands" {
    run grep -n '"test:installer:linux"' "$PROJECT_DIR/package.json"
    [ "$status" -eq 0 ]

    run grep -n '"test:installer:apt"' "$PROJECT_DIR/package.json"
    [ "$status" -eq 0 ]

    run grep -n '"test:installer:contracts"' "$PROJECT_DIR/package.json"
    [ "$status" -eq 0 ]
}

@test "Debian publish workflows write a promotion contract for the exact OpenPath SHA" {
    run grep -n 'promotion-contracts/\${OPENPATH_SHA}.json' "$PROJECT_DIR/.github/workflows/reusable-deb-publish.yml"
    [ "$status" -eq 0 ]

    run grep -n 'node scripts/openpath-promotion-contract.mjs write' "$PROJECT_DIR/.github/workflows/reusable-deb-publish.yml"
    [ "$status" -eq 0 ]

    run grep -n 'dpkg-deb -f "\${package_files\[0\]}" Version' "$PROJECT_DIR/.github/workflows/reusable-deb-publish.yml"
    [ "$status" -eq 0 ]

    run grep -n -- '--linux-agent-version "\${{ steps.deb_version.outputs.package_version }}"' "$PROJECT_DIR/.github/workflows/reusable-deb-publish.yml"
    [ "$status" -eq 0 ]
}

@test "prerelease Debian workflow uses monotonic timestamp package versions" {
    run grep -n 'date -u +%Y%m%d%H%M%S' "$PROJECT_DIR/.github/workflows/prerelease-deb.yml"
    [ "$status" -eq 0 ]

    run grep -n 'APT will not downgrade' "$PROJECT_DIR/.github/workflows/prerelease-deb.yml"
    [ "$status" -eq 0 ]
}

@test "apt bootstrap fails clearly when the selected track does not advertise openpath-dnsmasq" {
    run grep -n 'apt-cache show openpath-dnsmasq' "$PROJECT_DIR/linux/scripts/build/apt-bootstrap.sh"
    [ "$status" -eq 0 ]

    run grep -n 'APT repository metadata does not advertise openpath-dnsmasq' "$PROJECT_DIR/linux/scripts/build/apt-bootstrap.sh"
    [ "$status" -eq 0 ]

    run grep -n 'stable track is still serving the legacy whitelist-dnsmasq package' "$PROJECT_DIR/linux/scripts/build/apt-bootstrap.sh"
    [ "$status" -eq 0 ]
}

@test "active apt clients use raw GitHub while retaining legacy cleanup compatibility" {
    run grep -n 'https://raw.githubusercontent.com/balejosg/openpath/gh-pages/apt' "$PROJECT_DIR/linux/scripts/build/apt-setup.sh"
    [ "$status" -eq 0 ]

    run grep -n 'https://raw.githubusercontent.com/balejosg/openpath/gh-pages/apt' "$PROJECT_DIR/linux/scripts/build/apt-bootstrap.sh"
    [ "$status" -eq 0 ]

    run grep -n 'https://raw.githubusercontent.com/balejosg/openpath/gh-pages/apt' "$PROJECT_DIR/api/src/config-loader.ts"
    [ "$status" -eq 0 ]

    run grep -n 'balejosg.github.io' "$PROJECT_DIR/linux/scripts/build/apt-setup.sh"
    [ "$status" -ne 0 ]

    run grep -n 'LEGACY_GITHUB_PAGES_APT_REPO_URL="https://balejosg.github.io/openpath/apt"' "$PROJECT_DIR/linux/scripts/build/apt-bootstrap.sh"
    [ "$status" -eq 0 ]

    run grep -n 'OPENPATH_APT_REPO_URL:-https://balejosg.github.io/openpath/apt' "$PROJECT_DIR/linux/scripts/build/apt-bootstrap.sh"
    [ "$status" -ne 0 ]

    run grep -n 'balejosg.github.io' "$PROJECT_DIR/api/src/config-loader.ts"
    [ "$status" -ne 0 ]
}

@test "published Debian install commands use raw GitHub instead of legacy GitHub Pages" {
    run grep -n 'https://raw.githubusercontent.com/balejosg/openpath/gh-pages/apt/apt-bootstrap.sh' "$PROJECT_DIR/.github/workflows/build-deb.yml"
    [ "$status" -eq 0 ]

    run grep -n 'https://raw.githubusercontent.com/balejosg/openpath/gh-pages/apt/apt-bootstrap.sh' "$PROJECT_DIR/.github/workflows/prerelease-deb.yml"
    [ "$status" -eq 0 ]

    run grep -n 'https://raw.githubusercontent.com/balejosg/openpath/gh-pages/apt/apt-bootstrap.sh' "$PROJECT_DIR/.github/workflows/reusable-deb-publish.yml"
    [ "$status" -eq 0 ]

    run grep -n 'https://raw.githubusercontent.com/balejosg/openpath/gh-pages/apt/apt-setup.sh' "$PROJECT_DIR/.github/workflows/reusable-deb-publish.yml"
    [ "$status" -eq 0 ]

    run grep -n 'balejosg.github.io/openpath/apt' "$PROJECT_DIR/.github/workflows/build-deb.yml"
    [ "$status" -ne 0 ]

    run grep -n 'balejosg.github.io/openpath/apt' "$PROJECT_DIR/.github/workflows/prerelease-deb.yml"
    [ "$status" -ne 0 ]

    run grep -n 'balejosg.github.io/openpath/apt' "$PROJECT_DIR/.github/workflows/reusable-deb-publish.yml"
    [ "$status" -ne 0 ]
}

@test "protected control-plane domains no longer include legacy GitHub Pages" {
    run grep -n 'raw.githubusercontent.com' "$PROJECT_DIR/linux/lib/common-protected-domains.sh"
    [ "$status" -eq 0 ]

    run grep -n 'Common.Domains.ps1' "$PROJECT_DIR/windows/lib/Common.psm1"
    [ "$status" -eq 0 ]

    run grep -n 'raw.githubusercontent.com' "$PROJECT_DIR/windows/lib/internal/Common.Domains.ps1"
    [ "$status" -eq 0 ]

    run grep -n 'balejosg.github.io' "$PROJECT_DIR/linux/lib/common-protected-domains.sh"
    [ "$status" -ne 0 ]

    run grep -n 'balejosg.github.io' "$PROJECT_DIR/windows/lib/internal/Common.Domains.ps1"
    [ "$status" -ne 0 ]
}

@test "stable deb publish workflow re-signs existing APT suites before exporting the public key" {
    run grep -n 'uses: ./.github/workflows/reusable-deb-publish.yml' "$PROJECT_DIR/.github/workflows/build-deb.yml"
    [ "$status" -eq 0 ]

    run grep -n 'for suite in stable unstable; do' "$PROJECT_DIR/.github/workflows/reusable-deb-publish.yml"
    [ "$status" -eq 0 ]

    run grep -n 'reprepro export "\$suite"' "$PROJECT_DIR/.github/workflows/reusable-deb-publish.yml"
    [ "$status" -eq 0 ]
}

@test "stable deb publish workflow removes the legacy whitelist package before publishing" {
    run grep -n 'reprepro remove stable whitelist-dnsmasq || true' "$PROJECT_DIR/.github/workflows/reusable-deb-publish.yml"
    [ "$status" -eq 0 ]

    run grep -n 'remove-legacy-stable-package: true' "$PROJECT_DIR/.github/workflows/build-deb.yml"
    [ "$status" -eq 0 ]
}

@test "stable deb publish workflow validates the exported Packages metadata" {
    run grep -n 'Published APT metadata missing openpath-dnsmasq' "$PROJECT_DIR/.github/workflows/reusable-deb-publish.yml"
    [ "$status" -eq 0 ]

    run grep -n 'Legacy whitelist package leaked into stable metadata' "$PROJECT_DIR/.github/workflows/reusable-deb-publish.yml"
    [ "$status" -eq 0 ]

    run grep -n 'validate-published-metadata: true' "$PROJECT_DIR/.github/workflows/build-deb.yml"
    [ "$status" -eq 0 ]
}

@test "prerelease deb publish workflow waits for externally visible raw GitHub metadata" {
    run grep -n 'validate-published-metadata: true' "$PROJECT_DIR/.github/workflows/prerelease-deb.yml"
    [ "$status" -eq 0 ]

    run grep -n 'Wait for raw GitHub APT metadata publication' "$PROJECT_DIR/.github/workflows/reusable-deb-publish.yml"
    [ "$status" -eq 0 ]

    run grep -n 'https://raw.githubusercontent.com/balejosg/openpath/gh-pages/promotion-contracts/${OPENPATH_SHA}.json' "$PROJECT_DIR/.github/workflows/reusable-deb-publish.yml"
    [ "$status" -eq 0 ]

    run grep -n 'https://raw.githubusercontent.com/balejosg/openpath/gh-pages/apt/dists/$SUITE/main/binary-amd64/Packages' "$PROJECT_DIR/.github/workflows/reusable-deb-publish.yml"
    [ "$status" -eq 0 ]

    run grep -n 'openpath-dnsmasq=${{ steps.deb_version.outputs.package_version }}-1' "$PROJECT_DIR/.github/workflows/reusable-deb-publish.yml"
    [ "$status" -eq 0 ]
}

@test "deb publish workflow serializes apt repository updates across suites" {
    run grep -n 'group: openpath-apt-publish' "$PROJECT_DIR/.github/workflows/reusable-deb-publish.yml"
    [ "$status" -eq 0 ]
}

@test "deb publish workflow syncs deployed apt state back to gh-pages" {
    run grep -n 'git -C gh-pages add -A' "$PROJECT_DIR/.github/workflows/reusable-deb-publish.yml"
    [ "$status" -eq 0 ]

    run grep -n 'git -C gh-pages push origin HEAD:gh-pages' "$PROJECT_DIR/.github/workflows/reusable-deb-publish.yml"
    [ "$status" -eq 0 ]
}

@test "deb publish workflow validates carried-forward stable metadata on every publish" {
    run grep -n 'Existing stable metadata missing openpath-dnsmasq' "$PROJECT_DIR/.github/workflows/reusable-deb-publish.yml"
    [ "$status" -eq 0 ]

    run grep -n 'Existing stable metadata leaked whitelist-dnsmasq' "$PROJECT_DIR/.github/workflows/reusable-deb-publish.yml"
    [ "$status" -eq 0 ]
}

@test "deb publish workflow keeps prior openpath-dnsmasq versions advertised" {
    run grep -n 'copy_retained_suite_packages' "$PROJECT_DIR/.github/workflows/reusable-deb-publish.yml"
    [ "$status" -eq 0 ]

    run grep -n 'dpkg-scanpackages --arch amd64 --multiversion' "$PROJECT_DIR/.github/workflows/reusable-deb-publish.yml"
    [ "$status" -eq 0 ]

    run grep -n 'apt-ftparchive release "dists/\$suite"' "$PROJECT_DIR/.github/workflows/reusable-deb-publish.yml"
    [ "$status" -eq 0 ]

    run grep -n 'gpg --batch --yes --default-key "\$GPG_KEY_ID" --clearsign' "$PROJECT_DIR/.github/workflows/reusable-deb-publish.yml"
    [ "$status" -eq 0 ]
}

@test "stable deb publish workflow requires a persistent APT signing key" {
    run grep -n 'Missing APT_GPG_PRIVATE_KEY' "$PROJECT_DIR/.github/workflows/reusable-deb-publish.yml"
    [ "$status" -eq 0 ]

    run grep -n 'No GPG secret found, creating ephemeral key' "$PROJECT_DIR/.github/workflows/reusable-deb-publish.yml"
    [ "$status" -ne 0 ]
}

@test "prerelease deb publish workflow re-signs existing APT suites before exporting the public key" {
    run grep -n 'uses: ./.github/workflows/reusable-deb-publish.yml' "$PROJECT_DIR/.github/workflows/prerelease-deb.yml"
    [ "$status" -eq 0 ]

    run grep -n 'for suite in stable unstable; do' "$PROJECT_DIR/.github/workflows/reusable-deb-publish.yml"
    [ "$status" -eq 0 ]

    run grep -n 'reprepro export "\$suite"' "$PROJECT_DIR/.github/workflows/reusable-deb-publish.yml"
    [ "$status" -eq 0 ]
}

@test "prerelease deb publish workflow requires a persistent APT signing key" {
    run grep -n 'Missing APT_GPG_PRIVATE_KEY' "$PROJECT_DIR/.github/workflows/reusable-deb-publish.yml"
    [ "$status" -eq 0 ]

    run grep -n 'No GPG secret found, creating ephemeral key' "$PROJECT_DIR/.github/workflows/reusable-deb-publish.yml"
    [ "$status" -ne 0 ]
}

@test "APT signing key maintainer runbook documents the repository secret" {
    run grep -n 'gh secret set APT_GPG_PRIVATE_KEY --repo balejosg/openpath' "$PROJECT_DIR/docs/apt-signing-key.md"
    [ "$status" -eq 0 ]
}

@test "installer contracts workflow publishes a required summary check" {
    run grep -n 'name: Installer Contracts Success' "$PROJECT_DIR/.github/workflows/installer-contracts.yml"
    [ "$status" -eq 0 ]

    run grep -n -- '--require "Installer Contracts::Installer Contracts Success"' "$PROJECT_DIR/.github/workflows/release-scripts.yml"
    [ "$status" -eq 0 ]

    run grep -n 'npm run test:installer:contracts' "$PROJECT_DIR/.github/workflows/release-scripts.yml"
    [ "$status" -ne 0 ]

    run grep -n '/openpath/linux/uninstall.sh --auto-yes' "$PROJECT_DIR/tests/e2e/ci/run-linux-apt-contracts.sh"
    [ "$status" -eq 0 ]
}

@test "debconf templates use openpath-dnsmasq namespace" {
    run grep -n "^Template: openpath-dnsmasq/whitelist-url" "$PROJECT_DIR/linux/debian-package/DEBIAN/templates"
    [ "$status" -eq 0 ]

    run grep -n "^Template: openpath-dnsmasq/health-api-url" "$PROJECT_DIR/linux/debian-package/DEBIAN/templates"
    [ "$status" -eq 0 ]

    run grep -n "^Template: openpath-dnsmasq/health-api-secret" "$PROJECT_DIR/linux/debian-package/DEBIAN/templates"
    [ "$status" -eq 0 ]
}

@test "postinst reads canonical debconf keys" {
    run grep -n "db_get openpath-dnsmasq/whitelist-url" "$PROJECT_DIR/linux/debian-package/DEBIAN/postinst"
    [ "$status" -eq 0 ]

    run grep -n "db_get openpath-dnsmasq/health-api-url" "$PROJECT_DIR/linux/debian-package/DEBIAN/postinst"
    [ "$status" -eq 0 ]

    run grep -n "db_get openpath-dnsmasq/health-api-secret" "$PROJECT_DIR/linux/debian-package/DEBIAN/postinst"
    [ "$status" -eq 0 ]
}

@test "postinst only installs managed browser requests when request setup is complete" {
    run grep -n "is_openpath_request_setup_complete" "$PROJECT_DIR/linux/debian-package/DEBIAN/postinst"
    [ "$status" -eq 0 ]

    run grep -n "Skipping managed browser request integration until OpenPath setup is complete" "$PROJECT_DIR/linux/debian-package/DEBIAN/postinst"
    [ "$status" -eq 0 ]
}

@test "postinst starts persistent dns timers only after initial whitelist update" {
    local postinst_file="$PROJECT_DIR/linux/debian-package/DEBIAN/postinst"
    local initial_update_line
    local dns_reset_failed_line
    local dns_restart_line
    local dns_timer_start_line
    local watchdog_timer_start_line

    initial_update_line=$(grep -n "Running first update" "$postinst_file" | head -1 | cut -d: -f1)
    dns_reset_failed_line=$(grep -n "systemctl reset-failed dnsmasq" "$postinst_file" | head -1 | cut -d: -f1)
    dns_restart_line=$(grep -n "systemctl restart dnsmasq" "$postinst_file" | head -1 | cut -d: -f1)
    dns_timer_start_line=$(grep -n "systemctl start openpath-dnsmasq.timer" "$postinst_file" | head -1 | cut -d: -f1)
    watchdog_timer_start_line=$(grep -n "systemctl start dnsmasq-watchdog.timer" "$postinst_file" | head -1 | cut -d: -f1)

    [ -n "$initial_update_line" ]
    [ -n "$dns_reset_failed_line" ]
    [ -n "$dns_restart_line" ]
    [ -n "$dns_timer_start_line" ]
    [ -n "$watchdog_timer_start_line" ]
    [ "$dns_reset_failed_line" -lt "$dns_restart_line" ]
    [ "$initial_update_line" -lt "$dns_timer_start_line" ]
    [ "$initial_update_line" -lt "$watchdog_timer_start_line" ]
}

@test "setup dnsmasq restarts clear systemd start-limit state first" {
    local dns_lib="$PROJECT_DIR/linux/lib/dns-dnsmasq.sh"
    local install_steps="$PROJECT_DIR/linux/lib/install-core-steps.sh"

    run awk '
        /systemctl reset-failed dnsmasq/ { reset_line = NR }
        /timeout 30 systemctl restart dnsmasq/ {
            if (reset_line && reset_line < NR) found = 1
        }
        END { exit found ? 0 : 1 }
    ' "$dns_lib"
    [ "$status" -eq 0 ]

    run awk '
        /systemctl reset-failed dnsmasq/ { reset_line = NR }
        /systemctl restart dnsmasq/ {
            if (reset_line && reset_line < NR) found = 1
        }
        END { exit found ? 0 : 1 }
    ' "$install_steps"
    [ "$status" -eq 0 ]
}

@test "postinst ignores debconf fallback error strings when canonical whitelist key is empty" {
    local helper_script="$TEST_TMP_DIR/run-postinst-safe-debconf.sh"
    local state_dir="$TEST_TMP_DIR/postinst-state"

    mkdir -p "$state_dir"

    cat > "$helper_script" <<'EOF'
#!/bin/bash
set -euo pipefail

project_dir="$1"
state_dir="$2"
extracted_script="$state_dir/postinst-helpers.sh"

log_file="$state_dir/db-get.log"
: > "$log_file"

db_get() {
    printf '%s\n' "$1" >> "$log_file"
    case "$1" in
        openpath-dnsmasq/whitelist-url)
            RET=""
            return 0
            ;;
        whitelist-dnsmasq/whitelist-url)
            RET="10 whitelist-dnsmasq/whitelist-url doesn't exist"
            return 10
            ;;
        *)
            RET=""
            return 0
            ;;
    esac
}

awk '/^safe_db_get\(\) \{/,/^}/' \
    "$project_dir/linux/debian-package/DEBIAN/postinst" > "$extracted_script"
source "$extracted_script"

value="$(safe_db_get openpath-dnsmasq/whitelist-url whitelist-dnsmasq/whitelist-url)"
printf 'value=%s\n' "$value"
cat "$log_file"
EOF
    chmod +x "$helper_script"

    run "$helper_script" "$PROJECT_DIR" "$state_dir"

    [ "$status" -eq 0 ]
    [[ "$output" == *"value="* ]]
    [[ "$output" == *"openpath-dnsmasq/whitelist-url"* ]]
    [[ "$output" != *"whitelist-dnsmasq/whitelist-url"* ]]
    [[ "$output" != *"doesn't exist"* ]]
}

@test "postinst falls back to legacy whitelist debconf key only when canonical lookup fails" {
    local helper_script="$TEST_TMP_DIR/run-postinst-legacy-debconf-fallback.sh"
    local state_dir="$TEST_TMP_DIR/postinst-state"

    mkdir -p "$state_dir"

    cat > "$helper_script" <<'EOF'
#!/bin/bash
set -euo pipefail

project_dir="$1"
state_dir="$2"
extracted_script="$state_dir/postinst-helpers.sh"
log_file="$state_dir/db-get.log"

: > "$log_file"

db_get() {
    printf '%s\n' "$1" >> "$log_file"
    case "$1" in
        openpath-dnsmasq/whitelist-url)
            RET=""
            return 10
            ;;
        whitelist-dnsmasq/whitelist-url)
            RET="https://legacy.example.test/w/token/whitelist.txt"
            return 0
            ;;
        *)
            RET=""
            return 0
            ;;
    esac
}

awk '/^safe_db_get\(\) \{/,/^}/' \
    "$project_dir/linux/debian-package/DEBIAN/postinst" > "$extracted_script"
source "$extracted_script"

value="$(safe_db_get openpath-dnsmasq/whitelist-url whitelist-dnsmasq/whitelist-url)"
printf 'value=%s\n' "$value"
cat "$log_file"
EOF
    chmod +x "$helper_script"

    run "$helper_script" "$PROJECT_DIR" "$state_dir"

    [ "$status" -eq 0 ]
    [[ "$output" == *"value=https://legacy.example.test/w/token/whitelist.txt"* ]]
    [[ "$output" == *"openpath-dnsmasq/whitelist-url"* ]]
    [[ "$output" == *"whitelist-dnsmasq/whitelist-url"* ]]
}

@test "install.sh apt dependencies match debian control Depends" {
    local control_file="$PROJECT_DIR/linux/debian-package/DEBIAN/control"
    local install_file="$PROJECT_DIR/linux/lib/install-core-steps.sh"

    local depends_csv
    depends_csv=$(grep -E '^Depends:' "$control_file" | sed 's/^Depends:[[:space:]]*//')
    [ -n "$depends_csv" ]

    local control_pkgs
    control_pkgs=$(csv_to_lines "$depends_csv")

    # Every deb dependency must be installed by install.sh
    while IFS= read -r pkg; do
        [ -n "$pkg" ] || continue
        run grep -Eq "(^|[[:space:]])${pkg}([[:space:]]|$)" "$install_file"
        [ "$status" -eq 0 ]
    done <<< "$control_pkgs"

    # install.sh should not silently accumulate extra apt dependencies vs the deb
    local install_pkgs
    install_pkgs=$(
        awk '
            /apt-get install -y[[:space:]]*\\$/ {in=1; next}
            in {
                line=$0
                sub(/>.*/, "", line)
                gsub(/\\\\/, "", line)
                print line
                if ($0 ~ />\\/dev\\/null/) in=0
            }
            /apt-get install -y dnsmasq/ { print "dnsmasq" }
        ' "$install_file" \
            | tr -s '[:space:]' '\n' \
            | grep -v '^$' \
            | sort -u
    )

    while IFS= read -r pkg; do
        [ -n "$pkg" ] || continue
        echo "$control_pkgs" | grep -qx "$pkg"
    done <<< "$install_pkgs"
}

@test "linux package no longer requires iptables-persistent on modern Ubuntu hosts" {
    run grep -n 'iptables-persistent' "$PROJECT_DIR/linux/debian-package/DEBIAN/control"
    [ "$status" -ne 0 ]

    run grep -n 'iptables-persistent' "$PROJECT_DIR/linux/install.sh"
    [ "$status" -ne 0 ]

    run grep -n 'netfilter-persistent' "$PROJECT_DIR/linux/debian-package/DEBIAN/control"
    [ "$status" -ne 0 ]
}

@test "install.sh hardens apt operations against stale package indexes" {
    run grep -n "apt_update_with_retry()" "$PROJECT_DIR/linux/lib/apt.sh"
    [ "$status" -eq 0 ]

    run grep -n "rm -rf /var/lib/apt/lists/\\*" "$PROJECT_DIR/linux/lib/apt.sh"
    [ "$status" -eq 0 ]

    run grep -n 'Acquire::ForceIPv4 "true"' "$PROJECT_DIR/linux/lib/apt.sh"
    [ "$status" -eq 0 ]

    run grep -n "rewrite_ubuntu_sources_for_mirror" "$PROJECT_DIR/linux/lib/apt.sh"
    [ "$status" -eq 0 ]

    run grep -n 'timeout "\$timeout_seconds"' "$PROJECT_DIR/linux/lib/apt.sh"
    [ "$status" -eq 0 ]

    run grep -n 'OPENPATH_APT_INSTALL_TIMEOUT_SECONDS:-300' "$PROJECT_DIR/linux/lib/apt.sh"
    [ "$status" -eq 0 ]

    run grep -n 'apt_output_file="\$(mktemp)"' "$PROJECT_DIR/linux/lib/apt.sh"
    [ "$status" -eq 0 ]

    run grep -n '\[ -s "\$apt_output_file" \] && cat "\$apt_output_file"' "$PROJECT_DIR/linux/lib/apt.sh"
    [ "$status" -eq 0 ]

    run grep -n "apt_install_with_retry()" "$PROJECT_DIR/linux/lib/apt.sh"
    [ "$status" -eq 0 ]
}

@test "install.sh preserves the source tree after loading installed libraries" {
    run grep -n 'INSTALLER_SOURCE_DIR="\$SCRIPT_DIR"' "$PROJECT_DIR/linux/install.sh"
    [ "$status" -eq 0 ]

    run grep -n 'cp "\$INSTALLER_SOURCE_DIR/scripts/runtime/openpath-update.sh"' "$PROJECT_DIR/linux/lib/install-core-steps.sh"
    [ "$status" -eq 0 ]
}

@test "install.sh stages unattended linux agent updater runtime" {
    run grep -n 'cp "\$INSTALLER_SOURCE_DIR/scripts/runtime/openpath-agent-update.sh"' "$PROJECT_DIR/linux/lib/install-core-steps.sh"
    [ "$status" -eq 0 ]
}

@test "linux installers support quiet progress with explicit verbose mode" {
    run grep -n 'VERBOSE=false' "$PROJECT_DIR/linux/install.sh"
    [ "$status" -eq 0 ]

    run grep -n -- '--verbose' "$PROJECT_DIR/linux/install.sh"
    [ "$status" -eq 0 ]

    run grep -n 'show_progress()' "$PROJECT_DIR/linux/lib/install-helpers.sh"
    [ "$status" -eq 0 ]

    run grep -n 'INSTALLER_STEP_TOTAL=15' "$PROJECT_DIR/linux/install.sh"
    [ "$status" -eq 0 ]

    run grep -n 'run_installer_step 1 "\$INSTALLER_STEP_TOTAL" "Installing libraries" step_install_libraries' "$PROJECT_DIR/linux/install.sh"
    [ "$status" -eq 0 ]

    run grep -n 'ORIGINAL_ARGS=("\$@")' "$PROJECT_DIR/linux/install.sh"
    [ "$status" -eq 0 ]

    run grep -n 'exec sudo "\$0" "\${ORIGINAL_ARGS\[@\]}"' "$PROJECT_DIR/linux/install.sh"
    [ "$status" -eq 0 ]

    run grep -n -- '--verbose' "$PROJECT_DIR/linux/quick-install.sh"
    [ "$status" -eq 0 ]

    run grep -n 'installer_args+=(--verbose)' "$PROJECT_DIR/linux/quick-install.sh"
    [ "$status" -eq 0 ]

    run grep -n 'EXTRA_INSTALLER_ARGS+=("\$1")' "$PROJECT_DIR/linux/quick-install.sh"
    [ "$status" -eq 0 ]

    run grep -n 'installer_args+=("\${EXTRA_INSTALLER_ARGS\[@\]}")' "$PROJECT_DIR/linux/quick-install.sh"
    [ "$status" -eq 0 ]
}
