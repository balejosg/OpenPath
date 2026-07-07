#!/usr/bin/env bats
################################################################################
# linux-e2e.bats - Guardrails for Linux E2E lifecycle coverage
################################################################################

load 'test_helper'

@test "linux self-update script supports overriding release metadata for test harnesses" {
    run grep -nF 'OPENPATH_SELF_UPDATE_API' "$PROJECT_DIR/linux/lib/openpath-self-update-metadata.sh"
    [ "$status" -eq 0 ]
}

@test "linux self-update script supports api-hosted package manifests for managed clients" {
    run grep -nF '/api/agent/linux/manifest' "$PROJECT_DIR/linux/scripts/runtime/openpath-self-update.sh"
    [ "$status" -eq 0 ]

    run grep -nF 'get_machine_token_from_whitelist_url_file' "$PROJECT_DIR/linux/lib/openpath-self-update-metadata.sh"
    [ "$status" -eq 0 ]
}

@test "linux self-update reuses managed bearer auth for package downloads" {
    run grep -nF 'DOWNLOAD_AUTH_HEADER=' "$PROJECT_DIR/linux/scripts/runtime/openpath-self-update.sh"
    [ "$status" -eq 0 ]

    run grep -nF 'DOWNLOAD_AUTH_HEADER="$auth_header"' "$PROJECT_DIR/linux/lib/openpath-self-update-metadata.sh"
    [ "$status" -eq 0 ]

    run grep -nF 'curl -sS -L --connect-timeout 15 --max-time 120 -H "$DOWNLOAD_AUTH_HEADER" -o "$destination_file" "$source_url"' \
        "$PROJECT_DIR/linux/lib/openpath-self-update-package.sh"
    [ "$status" -eq 0 ]
}

@test "linux self-update computes bridge upgrade sequences from API manifest metadata" {
    run grep -nF 'BRIDGE_VERSIONS=()' "$PROJECT_DIR/linux/scripts/runtime/openpath-self-update.sh"
    [ "$status" -eq 0 ]

    run grep -nF 'resolve_update_sequence()' "$PROJECT_DIR/linux/lib/openpath-self-update-metadata.sh"
    [ "$status" -eq 0 ]

    run grep -nF 'bridgeVersions' "$PROJECT_DIR/linux/lib/openpath-self-update-metadata.sh"
    [ "$status" -eq 0 ]
}

@test "linux self-update caches rollback packages and can revert to the previous agent version" {
    run grep -nF 'PACKAGE_CACHE_DIR="${OPENPATH_AGENT_PACKAGE_CACHE_DIR:-$VAR_STATE_DIR/packages}"' \
        "$PROJECT_DIR/linux/scripts/runtime/openpath-self-update.sh"
    [ "$status" -eq 0 ]

    run grep -nF 'attempt_agent_package_rollback()' "$PROJECT_DIR/linux/lib/openpath-self-update-package.sh"
    [ "$status" -eq 0 ]

    run grep -nF '/api/agent/linux/packages/' "$PROJECT_DIR/linux/lib/openpath-self-update-metadata.sh"
    [ "$status" -eq 0 ]
}

@test "linux self-update keeps stdout reserved for cache path return values" {
    run grep -nF 'log "Caching OpenPath package v${version}..." >&2' \
        "$PROJECT_DIR/linux/lib/openpath-self-update-package.sh"
    [ "$status" -eq 0 ]

    run grep -nF 'log_error "Downloaded file is not a valid .deb package" >&2' \
        "$PROJECT_DIR/linux/lib/openpath-self-update-package.sh"
    [ "$status" -eq 0 ]
}

@test "linux self-update returns a clean cached package path when callers use command substitution" {
    run env PROJECT_DIR="$PROJECT_DIR" bash -lc '
        set -euo pipefail

        tmpdir=$(mktemp -d)
        trap "rm -rf \"$tmpdir\"" EXIT

        export INSTALL_DIR="$tmpdir/install"
        export ETC_CONFIG_DIR="$tmpdir/etc"
        export VAR_STATE_DIR="$tmpdir/var"
        export LOG_FILE="$tmpdir/openpath.log"
        mkdir -p "$INSTALL_DIR/lib" "$ETC_CONFIG_DIR" "$VAR_STATE_DIR"
        cp "$PROJECT_DIR/linux/lib/"*.sh "$INSTALL_DIR/lib/"

        pkgroot="$tmpdir/pkg-root"
        mkdir -p "$pkgroot/DEBIAN"
        cat > "$pkgroot/DEBIAN/control" <<'"'"'EOF'"'"'
Package: openpath-dnsmasq
Version: 1.2.3-1
Architecture: amd64
Maintainer: OpenPath Tests <tests@example.com>
Description: Test package
EOF
        dpkg-deb --build "$pkgroot" "$tmpdir/source.deb" >/dev/null

        export OPENPATH_SELF_UPDATE_SOURCE_ONLY=1
        # shellcheck source=/dev/null
        source "$PROJECT_DIR/linux/scripts/runtime/openpath-self-update.sh"

        PACKAGE_SOURCE="$tmpdir/source.deb"
        download_url_to_file() {
            local _source_url="$1"
            local destination_file="$2"
            mkdir -p "$(dirname "$destination_file")"
            cp "$PACKAGE_SOURCE" "$destination_file"
            verify_deb_package "$destination_file"
        }

        LATEST_VERSION="1.2.3"
        DOWNLOAD_URL="https://example.test/openpath-dnsmasq_1.2.3-1_amd64.deb"
        UPDATE_SOURCE="github-release"

        result=$(ensure_cached_package_for_version "1.2.3")
        expected="$VAR_STATE_DIR/packages/openpath-dnsmasq_1.2.3-1_amd64.deb"

        [ "$result" = "$expected" ]
        [ -f "$result" ]
    '
    [ "$status" -eq 0 ]
}

@test "linux self-update keeps bridge versions that lie between current and target releases" {
    run env PROJECT_DIR="$PROJECT_DIR" bash -lc '
        set -euo pipefail

        tmpdir=$(mktemp -d)
        trap "rm -rf \"$tmpdir\"" EXIT

        export INSTALL_DIR="$tmpdir/install"
        export ETC_CONFIG_DIR="$tmpdir/etc"
        export VAR_STATE_DIR="$tmpdir/var"
        export LOG_FILE="$tmpdir/openpath.log"
        mkdir -p "$INSTALL_DIR/lib" "$ETC_CONFIG_DIR" "$VAR_STATE_DIR"
        cp "$PROJECT_DIR/linux/lib/"*.sh "$INSTALL_DIR/lib/"

        export OPENPATH_SELF_UPDATE_SOURCE_ONLY=1
        # shellcheck source=/dev/null
        source "$PROJECT_DIR/linux/scripts/runtime/openpath-self-update.sh"

        BRIDGE_VERSIONS=("5.1.1")
        resolve_update_sequence "5.1.0" "5.1.2"

        [ "${#UPDATE_SEQUENCE[@]}" -eq 2 ]
        [ "${UPDATE_SEQUENCE[0]}" = "5.1.1" ]
        [ "${UPDATE_SEQUENCE[1]}" = "5.1.2" ]
    '
    [ "$status" -eq 0 ]
}

@test "linux self-update falls back to GitHub releases when the managed manifest returns an error payload" {
    run env PROJECT_DIR="$PROJECT_DIR" bash -lc '
        set -euo pipefail

        tmpdir=$(mktemp -d)
        trap "rm -rf \"$tmpdir\"" EXIT

        export INSTALL_DIR="$tmpdir/install"
        export ETC_CONFIG_DIR="$tmpdir/etc"
        export VAR_STATE_DIR="$tmpdir/var"
        export LOG_FILE="$tmpdir/openpath.log"
        mkdir -p "$INSTALL_DIR/lib" "$ETC_CONFIG_DIR" "$VAR_STATE_DIR"
        cp "$PROJECT_DIR/linux/lib/"*.sh "$INSTALL_DIR/lib/"

        export OPENPATH_SELF_UPDATE_SOURCE_ONLY=1
        export OPENPATH_SELF_UPDATE_API="https://managed.example/api/agent/linux/manifest"
        # shellcheck source=/dev/null
        source "$PROJECT_DIR/linux/scripts/runtime/openpath-self-update.sh"

        curl() {
            local url="${*: -1}"
            if [ "$url" = "https://managed.example/api/agent/linux/manifest" ]; then
                printf "%s" "{\"success\":false,\"error\":\"Linux agent package unavailable\"}"
                return 0
            fi

            if [ "$url" = "https://api.github.com/repos/balejosg/openpath/releases/latest" ]; then
                printf "%s" "{\"tag_name\":\"v9.9.9\",\"assets\":[{\"browser_download_url\":\"https://github.com/balejosg/openpath/releases/download/v9.9.9/openpath-dnsmasq_9.9.9-1_amd64.deb\"}]}"
                return 0
            fi

            echo "Unexpected curl URL: $url" >&2
            return 1
        }

        refresh_update_metadata

        [ "$UPDATE_SOURCE" = "github-release" ]
        [ "$LATEST_VERSION" = "9.9.9" ]
        [ "$DOWNLOAD_URL" = "https://github.com/balejosg/openpath/releases/download/v9.9.9/openpath-dnsmasq_9.9.9-1_amd64.deb" ]
        [ -z "$DOWNLOAD_AUTH_HEADER" ]
    '
    [ "$status" -eq 0 ]
}

@test "linux self-update validates dnsmasq health before declaring agent update success" {
    run grep -nF 'systemctl is-active --quiet dnsmasq' "$PROJECT_DIR/linux/lib/openpath-self-update-package.sh"
    [ "$status" -eq 0 ]
}

@test "linux self-update package repair has apt retry helper loaded" {
    run env PROJECT_DIR="$PROJECT_DIR" bash -lc '
        set -euo pipefail

        tmpdir=$(mktemp -d)
        trap "rm -rf \"$tmpdir\"" EXIT

        export INSTALL_DIR="$tmpdir/install"
        export ETC_CONFIG_DIR="$tmpdir/etc"
        export VAR_STATE_DIR="$tmpdir/var"
        export LOG_FILE="$tmpdir/openpath.log"
        mkdir -p "$INSTALL_DIR/lib" "$ETC_CONFIG_DIR" "$VAR_STATE_DIR"
        cp "$PROJECT_DIR/linux/lib/"*.sh "$INSTALL_DIR/lib/"

        export OPENPATH_SELF_UPDATE_SOURCE_ONLY=1
        # shellcheck source=/dev/null
        source "$PROJECT_DIR/linux/scripts/runtime/openpath-self-update.sh"

        declare -F apt_install_with_retry >/dev/null
    '
    [ "$status" -eq 0 ]
}

@test "linux self-update preserves request setup files and validates them after package updates" {
    run grep -nF '"/etc/openpath/api-url.conf"' "$PROJECT_DIR/linux/scripts/runtime/openpath-self-update.sh"
    [ "$status" -eq 0 ]

    run grep -nF '"/etc/openpath/classroom-id.conf"' "$PROJECT_DIR/linux/scripts/runtime/openpath-self-update.sh"
    [ "$status" -eq 0 ]

    run grep -nF 'require_openpath_request_setup_complete "post-update verification"' \
        "$PROJECT_DIR/linux/lib/openpath-self-update-package.sh"
    [ "$status" -eq 0 ]
}

@test "debian postinst runs strict Firefox setup only after dnsmasq is active" {
    run awk '
        /systemctl is-active --quiet dnsmasq/ { dnsmasq_active = NR }
        /openpath-browser-setup\.sh/ { browser_setup = NR }
        END {
            if (dnsmasq_active > 0 && browser_setup > dnsmasq_active) {
                exit 0
            }
            exit 1
        }
    ' "$PROJECT_DIR/linux/debian-package/DEBIAN/postinst"
    [ "$status" -eq 0 ]
}

@test "debian postinst keeps package configuration best-effort for Firefox setup" {
    run grep -nF 'detect_firefox_dir >/dev/null 2>&1' \
        "$PROJECT_DIR/linux/debian-package/DEBIAN/postinst"
    [ "$status" -eq 0 ]

    run grep -nF 'Skipping Firefox browser setup until Firefox is installed' \
        "$PROJECT_DIR/linux/debian-package/DEBIAN/postinst"
    [ "$status" -eq 0 ]

    run grep -nF 'Firefox browser setup failed; package configuration will continue' \
        "$PROJECT_DIR/linux/debian-package/DEBIAN/postinst"
    [ "$status" -eq 0 ]

    run grep -nF 'sudo /usr/local/bin/openpath-browser-setup.sh' \
        "$PROJECT_DIR/linux/debian-package/DEBIAN/postinst"
    [ "$status" -eq 0 ]
}

@test "linux student-policy e2e installs browser request integration only after setup" {
    run grep -nF './linux/install.sh --unattended --skip-firefox --with-native-host' \
        "$PROJECT_DIR/tests/e2e/ci/run-linux-student-flow.sh"
    [ "$status" -ne 0 ]

    run grep -nF './linux/install.sh --unattended --skip-firefox' \
        "$PROJECT_DIR/tests/e2e/ci/run-linux-student-flow.sh"
    [ "$status" -eq 0 ]

    run grep -nF '/usr/local/bin/openpath setup --api-url' \
        "$PROJECT_DIR/tests/e2e/ci/run-linux-student-flow.sh"
    [ "$status" -eq 0 ]

    run grep -nF '/usr/local/bin/openpath-browser-setup.sh' \
        "$PROJECT_DIR/tests/e2e/ci/run-linux-student-flow.sh"
    [ "$status" -eq 0 ]
}

@test "linux packaged updates keep the installed uninstaller available" {
    run grep -nF 'cp "$LINUX_DIR/uninstall.sh" "$BUILD_DIR/usr/local/lib/openpath/uninstall.sh"' "$PROJECT_DIR/linux/scripts/build/build-deb.sh"
    [ "$status" -eq 0 ]

    run grep -nF 'source "$INSTALLER_SOURCE_DIR/lib/install-core-steps.sh"' "$PROJECT_DIR/linux/install.sh"
    [ "$status" -eq 0 ]

    run grep -nF 'cp "$INSTALLER_SOURCE_DIR/uninstall.sh" "$INSTALL_DIR/uninstall.sh"' "$PROJECT_DIR/linux/lib/install-core-steps.sh"
    [ "$status" -eq 0 ]
}

@test "linux deb build stamps the target agent version into the packaged VERSION file" {
    run grep -nF "printf '%s\\n' \"\$VERSION\" > \"\$BUILD_DIR/usr/local/lib/openpath/VERSION\"" \
        "$PROJECT_DIR/linux/scripts/build/build-deb.sh"
    [ "$status" -eq 0 ]
}

@test "linux self-update does not ignore package repair failures" {
    run grep -nF 'apt-get -f install -y 2>&1 || true' "$PROJECT_DIR/linux/scripts/runtime/openpath-self-update.sh"
    [ "$status" -ne 0 ]
}

@test "linux debian postinst runs strict browser setup when request setup exists" {
    run grep -nF '/usr/local/bin/openpath-browser-setup.sh' "$PROJECT_DIR/linux/debian-package/DEBIAN/postinst"
    [ "$status" -eq 0 ]

    run grep -nF -- '--firefox-best-effort \' "$PROJECT_DIR/linux/debian-package/DEBIAN/postinst"
    [ "$status" -ne 0 ]
}

@test "linux apt contracts defer managed browser integration when setup is skipped" {
    run grep -nF 'test ! -f /usr/lib/mozilla/native-messaging-hosts/whitelist_native_host.json' \
        "$PROJECT_DIR/tests/e2e/ci/run-linux-apt-contracts.sh"
    [ "$status" -eq 0 ]

    run grep -nF '/openpath/linux/scripts/build/apt-bootstrap.sh --skip-setup' \
        "$PROJECT_DIR/tests/e2e/ci/run-linux-apt-contracts.sh"
    [ "$status" -eq 0 ]
}

@test "linux deb build includes browser native host assets" {
    run grep -nF 'stage_firefox_optional_extension_assets \' "$PROJECT_DIR/linux/scripts/build/build-deb.sh"
    [ "$status" -eq 0 ]

    run grep -nF '"$ROOT_DIR/firefox-extension" \' "$PROJECT_DIR/linux/scripts/build/build-deb.sh"
    [ "$status" -eq 0 ]

    run grep -nF '"$BUILD_DIR/usr/share/openpath/firefox-extension"' "$PROJECT_DIR/linux/scripts/build/build-deb.sh"
    [ "$status" -eq 0 ]
}

@test "linux deb build stages Firefox release artifacts when available" {
    run grep -nF 'source "$LINUX_DIR/lib/firefox-extension-assets.sh"' "$PROJECT_DIR/linux/scripts/build/build-deb.sh"
    [ "$status" -eq 0 ]

    run grep -nF 'stage_firefox_release_artifacts "$ROOT_DIR" "$firefox_release_destination"' "$PROJECT_DIR/linux/scripts/build/build-deb.sh"
    [ "$status" -eq 0 ]
}

@test "stable linux deb publish workflow requires staged Firefox release XPI artifacts" {
    run grep -nF 'OPENPATH_REQUIRE_FIREFOX_RELEASE_ARTIFACTS=1' "$PROJECT_DIR/linux/scripts/build/build-deb.sh"
    [ "$status" -eq 0 ]

    run grep -nF "OPENPATH_REQUIRE_FIREFOX_RELEASE_ARTIFACTS: '1'" "$PROJECT_DIR/.github/workflows/build-deb.yml"
    [ "$status" -eq 0 ]

    run grep -nF 'uses: ./.github/actions/prepare-firefox-release-artifacts' "$PROJECT_DIR/.github/workflows/build-deb.yml"
    [ "$status" -eq 0 ]
}

@test "prerelease linux deb publish workflow uses cached signed Firefox artifacts when available" {
    run grep -nF 'uses: ./.github/actions/prepare-firefox-release-artifacts' "$PROJECT_DIR/.github/workflows/prerelease-deb.yml"
    [ "$status" -eq 0 ]

    run grep -nF "sign-on-cache-miss: 'false'" "$PROJECT_DIR/.github/workflows/prerelease-deb.yml"
    [ "$status" -eq 0 ]

    run grep -nF "require-signed-artifacts: 'false'" "$PROJECT_DIR/.github/workflows/prerelease-deb.yml"
    [ "$status" -eq 0 ]

    run grep -nF "OPENPATH_REQUIRE_FIREFOX_RELEASE_ARTIFACTS: '1'" "$PROJECT_DIR/.github/workflows/prerelease-deb.yml"
    [ "$status" -ne 0 ]

    run grep -nF 'Firefox Release artifact source: ${{ steps.firefox-release.outputs.artifact-source }}' "$PROJECT_DIR/.github/workflows/prerelease-deb.yml"
    [ "$status" -eq 0 ]
}

@test "linux install script stages Firefox release artifacts when available" {
    run grep -nF 'source "$INSTALLER_SOURCE_DIR/lib/install-runtime-steps.sh"' "$PROJECT_DIR/linux/install.sh"
    [ "$status" -eq 0 ]

    run grep -nF 'stage_firefox_release_artifacts "$INSTALLER_SOURCE_DIR" "$staged_release_dir"' "$PROJECT_DIR/linux/lib/install-runtime-steps.sh"
    [ "$status" -eq 0 ]

    run grep -nF 'stage_firefox_installation_bundle "$INSTALLER_SOURCE_DIR/firefox-extension" "$staged_ext_dir"' "$PROJECT_DIR/linux/lib/install-runtime-steps.sh"
    [ "$status" -eq 0 ]
}

@test "linux install script skips browser extensions until request setup is complete" {
    run grep -nF 'Extensiones del navegador omitidas hasta completar OpenPath setup' "$PROJECT_DIR/linux/lib/install-runtime-steps.sh"
    [ "$status" -eq 0 ]
}

@test "linux e2e can require firefox extension presence explicitly" {
    run grep -n 'OPENPATH_EXPECT_FIREFOX_EXTENSION' "$PROJECT_DIR/tests/e2e/linux-e2e-tests.sh"
    [ "$status" -eq 0 ]
}

@test "linux e2e allows installer-mode runs without request setup files" {
    run grep -nF "Request setup not configured (installer mode)" "$PROJECT_DIR/tests/e2e/linux-e2e-tests.sh"
    [ "$status" -eq 0 ]

    run grep -nF "whitelist-url.conf missing while request setup markers exist" "$PROJECT_DIR/tests/e2e/linux-e2e-tests.sh"
    [ "$status" -eq 0 ]
}

@test "linux browser library delegates Firefox policy and managed release helpers to dedicated modules" {
    run grep -nF 'source "$_browser_lib_dir/firefox-policy.sh"' "$PROJECT_DIR/linux/lib/browser.sh"
    [ "$status" -eq 0 ]

    run grep -nF 'source "$_browser_lib_dir/firefox-managed-extension.sh"' "$PROJECT_DIR/linux/lib/browser.sh"
    [ "$status" -eq 0 ]

    run grep -nF 'source "$_browser_lib_dir/browser-request-readiness.sh"' "$PROJECT_DIR/linux/lib/browser.sh"
    [ "$status" -eq 0 ]

    run grep -nF 'source "$_browser_lib_dir/browser-firefox.sh"' "$PROJECT_DIR/linux/lib/browser.sh"
    [ "$status" -eq 0 ]

    run grep -nF 'source "$_browser_lib_dir/browser-native-host.sh"' "$PROJECT_DIR/linux/lib/browser.sh"
    [ "$status" -eq 0 ]
}

@test "linux integrity baseline tracks dedicated Firefox helper modules" {
    run grep -nF '"$INSTALL_DIR/lib/firefox-policy.sh"' "$PROJECT_DIR/linux/lib/common.sh"
    [ "$status" -eq 0 ]

    run grep -nF '"$INSTALL_DIR/lib/firefox-managed-extension.sh"' "$PROJECT_DIR/linux/lib/common.sh"
    [ "$status" -eq 0 ]

    run grep -nF '"$INSTALL_DIR/lib/browser-request-readiness.sh"' "$PROJECT_DIR/linux/lib/common.sh"
    [ "$status" -eq 0 ]

    run grep -nF '"$INSTALL_DIR/lib/browser-firefox.sh"' "$PROJECT_DIR/linux/lib/common.sh"
    [ "$status" -eq 0 ]

    run grep -nF '"$INSTALL_DIR/lib/openpath-self-update-package.sh"' "$PROJECT_DIR/linux/lib/common.sh"
    [ "$status" -eq 0 ]
}

@test "linux pre-install validation follows shared Firefox asset staging helpers" {
    run grep -nF 'stage_firefox_unpacked_extension_assets "$ext_source" "$ext_dir" || return 1' "$PROJECT_DIR/linux/lib/firefox-managed-extension.sh"
    [ "$status" -eq 0 ]

    run grep -nF 'dist/background.js|file|extension build artifact' "$PROJECT_DIR/linux/lib/firefox-extension-assets.sh"
    [ "$status" -eq 0 ]

    run grep -nF 'dist/popup.js|file|extension build artifact' "$PROJECT_DIR/linux/lib/firefox-extension-assets.sh"
    [ "$status" -eq 0 ]

    run grep -nF 'dist/lib|dir|extension build artifact directory' "$PROJECT_DIR/linux/lib/firefox-extension-assets.sh"
    [ "$status" -eq 0 ]

    run grep -nF 'blocked/blocked.html|file|extension blocked screen' "$PROJECT_DIR/linux/lib/firefox-extension-assets.sh"
    [ "$status" -eq 0 ]

    run grep -nF 'installer delegates unpacked Firefox asset staging to the shared helper' "$PROJECT_DIR/tests/e2e/pre-install-validation.sh"
    [ "$status" -eq 0 ]

    run grep -nF 'Firefox asset helper no longer requires dist/config.js' "$PROJECT_DIR/tests/e2e/pre-install-validation.sh"
    [ "$status" -eq 0 ]
}

@test "linux uninstall restores resolv.conf with a copy fallback when symlink replacement is blocked" {
    run grep -nF 'cp /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf' "$PROJECT_DIR/linux/uninstall.sh"
    [ "$status" -eq 0 ]
}

@test "linux uninstall only resets Firefox policies when the policy directory exists" {
    run grep -nF 'if [ -d /etc/firefox/policies ]; then' "$PROJECT_DIR/linux/uninstall.sh"
    [ "$status" -eq 0 ]

    run grep -nF 'if [ -d /etc/firefox/policies ]; then' "$PROJECT_DIR/linux/debian-package/DEBIAN/postrm"
    [ "$status" -eq 0 ]
}

@test "linux lifecycle e2e covers agent self-update and uninstall verification" {
    run grep -nF "Testing agent self-update mechanism (openpath-self-update.sh)..." "$PROJECT_DIR/tests/e2e/ci/run-linux-e2e.sh"
    [ "$status" -eq 0 ]

    run grep -nF "test-update-token" "$PROJECT_DIR/tests/e2e/ci/run-linux-e2e.sh"
    [ "$status" -eq 0 ]

    run grep -nF "self-update-test-token" "$PROJECT_DIR/tests/e2e/ci/run-linux-e2e.sh"
    [ "$status" -eq 0 ]

    run grep -nF '"downloadPath": "/$deb_name"' "$PROJECT_DIR/tests/e2e/ci/run-linux-e2e.sh"
    [ "$status" -eq 0 ]

    run grep -nF 'api/agent/linux/packages/$current_version' "$PROJECT_DIR/tests/e2e/ci/run-linux-e2e.sh"
    [ "$status" -eq 0 ]

    run grep -nF "Testing agent bridge upgrade and rollback mechanism..." "$PROJECT_DIR/tests/e2e/ci/run-linux-e2e.sh"
    [ "$status" -eq 0 ]

    run grep -nF "Verifying Linux uninstall removes installed state..." "$PROJECT_DIR/tests/e2e/ci/run-linux-e2e.sh"
    [ "$status" -eq 0 ]

    run grep -nF "/usr/local/lib/openpath/uninstall.sh --auto-yes" "$PROJECT_DIR/tests/e2e/ci/run-linux-e2e.sh"
    [ "$status" -eq 0 ]
}

@test "linux gh actions workflow runs Linux e2e coverage on Ubuntu runners" {
    run grep -nF 'os: [ubuntu-22.04, ubuntu-24.04]' "$PROJECT_DIR/.github/workflows/e2e-tests.yml"
    [ "$status" -eq 0 ]

    run grep -nF 'bash tests/e2e/ci/run-linux-e2e.sh' "$PROJECT_DIR/.github/workflows/e2e-tests.yml"
    [ "$status" -eq 0 ]
}

@test "linux e2e container uses runner DNS instead of hard-coded public DNS" {
    run grep -nF 'collect_docker_dns_args' "$PROJECT_DIR/tests/e2e/ci/run-linux-e2e.sh"
    [ "$status" -eq 0 ]

    run grep -nF 'OPENPATH_E2E_DOCKER_DNS' "$PROJECT_DIR/tests/e2e/ci/run-linux-e2e.sh"
    [ "$status" -eq 0 ]

    run grep -nF 'DNS candidate from /etc/resolv.conf' "$PROJECT_DIR/tests/e2e/ci/run-linux-e2e.sh"
    [ "$status" -eq 0 ]

    run grep -nF 'Accepted DNS server for E2E container' "$PROJECT_DIR/tests/e2e/ci/run-linux-e2e.sh"
    [ "$status" -eq 0 ]

    run grep -nF 'Discarded DNS server for E2E container' "$PROJECT_DIR/tests/e2e/ci/run-linux-e2e.sh"
    [ "$status" -eq 0 ]

    run grep -nF 'OPENPATH_E2E_DOCKER_DNS is set; using explicit E2E container DNS' "$PROJECT_DIR/tests/e2e/ci/run-linux-e2e.sh"
    [ "$status" -eq 0 ]

    run grep -nF 'OPENPATH_E2E_DOCKER_DNS is not set; Docker default DNS will be used' "$PROJECT_DIR/tests/e2e/ci/run-linux-e2e.sh"
    [ "$status" -eq 0 ]

    run grep -nF '--dns 8.8.8.8' "$PROJECT_DIR/tests/e2e/ci/run-linux-e2e.sh"
    [ "$status" -ne 0 ]
}

@test "linux runtime includes unattended agent update wrapper and systemd wiring" {
    run grep -nF 'source "$INSTALLER_SOURCE_DIR/lib/install-core-steps.sh"' "$PROJECT_DIR/linux/install.sh"
    [ "$status" -eq 0 ]

    run grep -nF 'openpath-agent-update.sh' "$PROJECT_DIR/linux/lib/install-core-steps.sh"
    [ "$status" -eq 0 ]

    run grep -nF 'openpath-agent-update.sh' "$PROJECT_DIR/linux/scripts/build/build-deb.sh"
    [ "$status" -eq 0 ]

    run grep -nF 'openpath-agent-update.timer' "$PROJECT_DIR/linux/lib/services.sh"
    [ "$status" -eq 0 ]

    run grep -nF 'openpath-agent-update.service' "$PROJECT_DIR/linux/lib/services.sh"
    [ "$status" -eq 0 ]
}

@test "linux debian package ships static systemd units for unattended agent updates" {
    run test -f "$PROJECT_DIR/linux/debian-package/lib/systemd/system/openpath-agent-update.service"
    [ "$status" -eq 0 ]

    run test -f "$PROJECT_DIR/linux/debian-package/lib/systemd/system/openpath-agent-update.timer"
    [ "$status" -eq 0 ]

    run grep -nF 'ExecStart=/usr/local/bin/openpath-agent-update.sh' \
        "$PROJECT_DIR/linux/debian-package/lib/systemd/system/openpath-agent-update.service"
    [ "$status" -eq 0 ]

    run grep -nF 'RandomizedDelaySec=6h' \
        "$PROJECT_DIR/linux/debian-package/lib/systemd/system/openpath-agent-update.timer"
    [ "$status" -eq 0 ]
}

@test "linux debian maintainer scripts manage unattended agent update timer lifecycle" {
    run grep -nF 'systemctl enable openpath-agent-update.timer' \
        "$PROJECT_DIR/linux/debian-package/DEBIAN/postinst"
    [ "$status" -eq 0 ]

    run grep -nF 'systemctl start openpath-agent-update.timer' \
        "$PROJECT_DIR/linux/debian-package/DEBIAN/postinst"
    [ "$status" -eq 0 ]

    run grep -nF 'systemctl stop openpath-agent-update.timer' \
        "$PROJECT_DIR/linux/debian-package/DEBIAN/prerm"
    [ "$status" -eq 0 ]

    run grep -nF 'systemctl disable openpath-agent-update.timer' \
        "$PROJECT_DIR/linux/debian-package/DEBIAN/prerm"
    [ "$status" -eq 0 ]
}

@test "windows installer stages Firefox release extension artifacts when available" {
    run grep -nF '$OpenPathRoot\browser-extension\firefox' "$PROJECT_DIR/windows/lib/install/Installer.Staging.ps1"
    [ "$status" -eq 0 ]

    run grep -nF '$OpenPathRoot\browser-extension\firefox-release' "$PROJECT_DIR/windows/lib/install/Installer.Staging.ps1"
    [ "$status" -eq 0 ]
}

@test "windows installer stages Chromium managed rollout metadata when available" {
    run grep -nF '$chromiumManagedCandidates = @(' "$PROJECT_DIR/windows/lib/install/Installer.Staging.ps1"
    [ "$status" -eq 0 ]

    run grep -nF 'firefox-extension\build\chromium-managed' "$PROJECT_DIR/windows/lib/install/Installer.Staging.ps1"
    [ "$status" -eq 0 ]

    run grep -nF '$OpenPathRoot\browser-extension\chromium-managed' "$PROJECT_DIR/windows/lib/install/Installer.Staging.ps1"
    [ "$status" -eq 0 ]
}

@test "windows installer supports unmanaged Chromium store guidance" {
    run grep -nF '[string]$ChromeExtensionStoreUrl = ""' "$PROJECT_DIR/windows/Install-OpenPath.ps1"
    [ "$status" -eq 0 ]

    run grep -nF '[string]$EdgeExtensionStoreUrl = ""' "$PROJECT_DIR/windows/Install-OpenPath.ps1"
    [ "$status" -eq 0 ]

    run grep -nF '$OpenPathRoot\browser-extension\chromium-unmanaged' "$PROJECT_DIR/windows/lib/install/Installer.ChromiumGuidance.ps1"
    [ "$status" -eq 0 ]
}

@test "windows browser policies only force-install Firefox from signed distribution settings" {
    run grep -nF 'Import-Module "$PSScriptRoot\Browser.Common.psm1"' "$PROJECT_DIR/windows/lib/Browser.psm1"
    [ "$status" -eq 0 ]

    run grep -nF 'Import-Module "$PSScriptRoot\Browser.FirefoxPolicy.psm1"' "$PROJECT_DIR/windows/lib/Browser.psm1"
    [ "$status" -eq 0 ]

    run grep -nF 'Import-Module "$PSScriptRoot\Browser.FirefoxNativeHost.psm1"' "$PROJECT_DIR/windows/lib/Browser.psm1"
    [ "$status" -eq 0 ]

    run grep -nF 'Import-Module "$PSScriptRoot\Browser.Diagnostics.psm1"' "$PROJECT_DIR/windows/lib/Browser.psm1"
    [ "$status" -eq 0 ]

    run grep -nF "Source = 'managed-api'" "$PROJECT_DIR/windows/lib/Browser.FirefoxPolicy.psm1"
    [ "$status" -eq 0 ]

    run grep -nF "Source = 'staged-release'" "$PROJECT_DIR/windows/lib/Browser.FirefoxPolicy.psm1"
    [ "$status" -eq 0 ]

    run grep -nF "Source = 'metadata-install-url'" "$PROJECT_DIR/windows/lib/Browser.FirefoxPolicy.psm1"
    [ "$status" -eq 0 ]
}

@test "linux runtime stages the shared browser-json helper" {
    run grep -nF 'source "$INSTALLER_SOURCE_DIR/lib/install-core-steps.sh"' "$PROJECT_DIR/linux/install.sh"
    [ "$status" -eq 0 ]

    run grep -nF '$INSTALLER_SOURCE_DIR/libexec/browser-json.py' "$PROJECT_DIR/linux/lib/install-core-steps.sh"
    [ "$status" -eq 0 ]

    run grep -nF '"$INSTALL_DIR/libexec/browser-json.py"' "$PROJECT_DIR/linux/lib/common.sh"
    [ "$status" -eq 0 ]

    run test -f "$PROJECT_DIR/linux/libexec/browser-json.py"
    [ "$status" -eq 0 ]
}

@test "linux runtime stages runtime dependency apply assets" {
    run grep -nF '$INSTALLER_SOURCE_DIR/libexec/runtime-dependency-overlay.py' "$PROJECT_DIR/linux/lib/install-core-steps.sh"
    [ "$status" -eq 0 ]

    run grep -nF '$INSTALLER_SOURCE_DIR/scripts/runtime/openpath-runtime-dependency-apply.sh' "$PROJECT_DIR/linux/lib/install-core-steps.sh"
    [ "$status" -eq 0 ]

    run grep -nF '$LINUX_DIR/libexec/runtime-dependency-overlay.py' "$PROJECT_DIR/linux/scripts/build/build-deb.sh"
    [ "$status" -eq 0 ]

    run grep -nF '$LINUX_DIR/scripts/runtime/openpath-runtime-dependency-apply.sh' "$PROJECT_DIR/linux/scripts/build/build-deb.sh"
    [ "$status" -eq 0 ]

    run test -f "$PROJECT_DIR/linux/libexec/runtime-dependency-overlay.py"
    [ "$status" -eq 0 ]

    run test -f "$PROJECT_DIR/linux/scripts/runtime/openpath-runtime-dependency-apply.sh"
    [ "$status" -eq 0 ]
}

@test "linux runtime dependency lifecycle removes service units and state" {
    run grep -nF '/etc/systemd/system/openpath-runtime-dependency-apply.service' "$PROJECT_DIR/linux/uninstall.sh" "$PROJECT_DIR/linux/debian-package/DEBIAN/postrm"
    [ "$status" -eq 0 ]

    run grep -nF '/etc/systemd/system/openpath-runtime-dependency-apply.path' "$PROJECT_DIR/linux/uninstall.sh" "$PROJECT_DIR/linux/debian-package/DEBIAN/postrm"
    [ "$status" -eq 0 ]

    run grep -nF '/usr/local/bin/openpath-runtime-dependency-apply.sh' "$PROJECT_DIR/linux/uninstall.sh" "$PROJECT_DIR/linux/debian-package/DEBIAN/postrm"
    [ "$status" -eq 0 ]

    run grep -nF '/usr/local/lib/openpath/libexec/runtime-dependency-overlay.py' "$PROJECT_DIR/linux/debian-package/DEBIAN/postrm"
    [ "$status" -eq 0 ]

    run grep -nF '/var/lib/openpath/runtime-dependency-overlay.json' "$PROJECT_DIR/linux/uninstall.sh" "$PROJECT_DIR/linux/debian-package/DEBIAN/postrm"
    [ "$status" -eq 0 ]
}

@test "linux runtime dependency install keeps python3 and provisions queue directories" {
    run grep -nF 'libcap2-bin dnsutils conntrack python3' "$PROJECT_DIR/linux/lib/install-core-steps.sh"
    [ "$status" -eq 0 ]

    run grep -nF 'Depends: dnsmasq, iptables, ipset, iproute2, curl, libcap2-bin, dnsutils, conntrack, python3' "$PROJECT_DIR/linux/debian-package/DEBIAN/control"
    [ "$status" -eq 0 ]

    run grep -nF 'chmod 1733 "$VAR_STATE_DIR/runtime-dependency-queue"' "$PROJECT_DIR/linux/lib/install-core-steps.sh"
    [ "$status" -eq 0 ]

    run grep -nF 'chmod 0700 "$VAR_STATE_DIR/runtime-dependency-rejected"' "$PROJECT_DIR/linux/lib/install-core-steps.sh"
    [ "$status" -eq 0 ]
}

@test "linux install script stages chromium browser helper modules required by common.sh" {
    run grep -nF 'source "$INSTALLER_SOURCE_DIR/lib/install-core-steps.sh"' "$PROJECT_DIR/linux/install.sh"
    [ "$status" -eq 0 ]

    run grep -nF 'cp "$INSTALLER_SOURCE_DIR/lib/"*.sh "$INSTALL_DIR/lib/"' "$PROJECT_DIR/linux/lib/install-core-steps.sh"
    [ "$status" -eq 0 ]

    run grep -nF '"$INSTALL_DIR/lib/chromium-managed-extension.sh"' "$PROJECT_DIR/linux/lib/common.sh"
    [ "$status" -eq 0 ]
}

@test "browser runtimes stage the shared browser policy spec" {
    run grep -nF 'source "$INSTALLER_SOURCE_DIR/lib/install-core-steps.sh"' "$PROJECT_DIR/linux/install.sh"
    [ "$status" -eq 0 ]

    run grep -nF '$INSTALLER_SOURCE_DIR/../runtime/browser-policy-spec.json' "$PROJECT_DIR/linux/lib/install-core-steps.sh"
    [ "$status" -eq 0 ]

    run grep -nF '$LINUX_DIR/../runtime/browser-policy-spec.json' "$PROJECT_DIR/linux/scripts/build/build-deb.sh"
    [ "$status" -eq 0 ]

    run grep -nF "Installer.Staging.ps1" "$PROJECT_DIR/windows/Install-OpenPath.ps1"
    [ "$status" -eq 0 ]

    run grep -nF 'runtime\browser-policy-spec.json' "$PROJECT_DIR/windows/lib/install/Installer.Staging.ps1"
    [ "$status" -eq 0 ]

    run test -f "$PROJECT_DIR/runtime/browser-policy-spec.json"
    [ "$status" -eq 0 ]
}

@test "linux e2e docker contexts copy runtime browser policy spec" {
    run grep -nF 'COPY runtime/ ./runtime/' "$PROJECT_DIR/tests/e2e/Dockerfile"
    [ "$status" -eq 0 ]

    run grep -nF 'COPY runtime/ ./runtime/' "$PROJECT_DIR/tests/e2e/Dockerfile.student"
    [ "$status" -eq 0 ]

    run grep -nF 'COPY runtime/ ./runtime/' "$PROJECT_DIR/tests/e2e/ci/run-linux-apt-contracts.sh"
    [ "$status" -eq 0 ]

    run grep -nF 'mkdir -p "$tmp/linux" "$tmp/runtime" "$tmp/tests/e2e" "$tmp/tests/contracts" "$tmp/firefox-extension" "$tmp/windows"' "$PROJECT_DIR/tests/e2e/ci/run-linux-e2e.sh"
    [ "$status" -eq 0 ]

    run grep -nF 'cp -a "$PROJECT_ROOT/runtime/." "$tmp/runtime/"' "$PROJECT_DIR/tests/e2e/ci/run-linux-e2e.sh"
    [ "$status" -eq 0 ]

    run grep -nF 'mkdir -p "$tmp/linux" "$tmp/runtime" "$tmp/windows" "$tmp/tests/e2e" "$tmp/tests/selenium" "$tmp/firefox-extension"' "$PROJECT_DIR/tests/e2e/ci/run-linux-student-flow.sh"
    [ "$status" -eq 0 ]

    run grep -nF 'cp -a "$PROJECT_ROOT/runtime/." "$tmp/runtime/"' "$PROJECT_DIR/tests/e2e/ci/run-linux-student-flow.sh"
    [ "$status" -eq 0 ]

    run grep -nF 'mkdir -p "$tmp/linux" "$tmp/runtime"' "$PROJECT_DIR/tests/e2e/ci/run-linux-apt-contracts.sh"
    [ "$status" -eq 0 ]

    run grep -nF 'cp -a "$PROJECT_ROOT/runtime/." "$tmp/runtime/"' "$PROJECT_DIR/tests/e2e/ci/run-linux-apt-contracts.sh"
    [ "$status" -eq 0 ]
}

@test "release scripts package the shared runtime assets" {
    run grep -nF 'runtime/' "$PROJECT_DIR/.github/workflows/release-scripts.yml"
    [ "$status" -eq 0 ]

    run grep -nF 'Shared runtime assets (`runtime/`)' "$PROJECT_DIR/.github/workflows/release-scripts.yml"
    [ "$status" -eq 0 ]
}

@test "windows installer and release scripts stage browser policy runtime assets compatibly" {
    run grep -nF "Installer.Staging.ps1" "$PROJECT_DIR/windows/Install-OpenPath.ps1"
    [ "$status" -eq 0 ]

    run grep -nF 'runtime\browser-policy-spec.json' "$PROJECT_DIR/windows/lib/install/Installer.Staging.ps1"
    [ "$status" -eq 0 ]

    run grep -nF 'zip -r -q "$PACKAGE_NAME" windows/ runtime/ VERSION' "$PROJECT_DIR/.github/workflows/release-scripts.yml"
    [ "$status" -eq 0 ]
}

@test "windows browser Pester coverage is split into focused suites with shared helpers" {
    run test -f "$PROJECT_DIR/windows/tests/TestHelpers.ps1"
    [ "$status" -eq 0 ]

    run test -f "$PROJECT_DIR/windows/tests/TestHelpers.psm1"
    [ "$status" -eq 0 ]

    run test -f "$PROJECT_DIR/windows/tests/Windows.Browser.FirefoxPolicy.Tests.ps1"
    [ "$status" -eq 0 ]

    run test -f "$PROJECT_DIR/windows/tests/Windows.Browser.ChromiumPolicy.Tests.ps1"
    [ "$status" -eq 0 ]

    run test -f "$PROJECT_DIR/windows/tests/Windows.Browser.NativeHost.Tests.ps1"
    [ "$status" -eq 0 ]

    run test -f "$PROJECT_DIR/windows/tests/Windows.Browser.Diagnostics.Tests.ps1"
    [ "$status" -eq 0 ]

    run grep -nF 'Import-Module (Join-Path $PSScriptRoot "TestHelpers.psm1") -Force' "$PROJECT_DIR/windows/tests/Windows.Browser.FirefoxPolicy.Tests.ps1"
    [ "$status" -eq 0 ]

    run grep -nF 'Describe "Browser Module"' "$PROJECT_DIR/windows/tests/Windows.Tests.ps1"
    [ "$status" -ne 0 ]
}

@test "windows browser suites load shared browser contract fixtures" {
    run grep -nF 'browser-firefox-managed-extension.json' "$PROJECT_DIR/windows/tests/Windows.Browser.FirefoxPolicy.Tests.ps1"
    [ "$status" -eq 0 ]

    run grep -nF 'browser-chromium-policy.json' "$PROJECT_DIR/windows/tests/Windows.Browser.ChromiumPolicy.Tests.ps1"
    [ "$status" -eq 0 ]

    run grep -nF 'Get-ContractFixtureJson' "$PROJECT_DIR/windows/tests/TestHelpers.psm1"
    [ "$status" -eq 0 ]
}

@test "windows installer explains Firefox Release requires a signed extension distribution" {
    run grep -nF 'Firefox Release extension auto-install requires a signed XPI distribution (AMO, HTTPS URL, or staged signed artifact).' "$PROJECT_DIR/windows/lib/install/Installer.Staging.ps1"
    [ "$status" -eq 0 ]
}

@test "windows installer explains that Chrome and Edge extension rollout requires managed distribution" {
    run grep -nF 'Chrome/Edge force-install is not available on unmanaged Windows; use store guidance, Firefox auto-install, or a managed CRX/update-manifest rollout.' "$PROJECT_DIR/windows/lib/install/Installer.Staging.ps1"
    [ "$status" -eq 0 ]
}

# ============== DNS-sinkhole <-> firewall contract single-owner pins ==============

@test "sinkhole IP default literals have exactly one owner in linux/lib (defaults.conf)" {
    run grep -rl -- ':-192\.0\.2\.1' "$PROJECT_DIR/linux/lib"
    [ "$status" -eq 0 ]
    [ "$output" = "$PROJECT_DIR/linux/lib/defaults.conf" ]

    run grep -rl -- ':-100::' "$PROJECT_DIR/linux/lib"
    [ "$status" -eq 0 ]
    [ "$output" = "$PROJECT_DIR/linux/lib/defaults.conf" ]
}

@test "ip6tables availability is probed only by the contract owner" {
    run grep -rl -- 'command -v ip6tables' "$PROJECT_DIR/linux/lib"
    [ "$status" -eq 0 ]
    [ "$output" = "$PROJECT_DIR/linux/lib/dns-firewall-contract.sh" ]
}

@test "dns-dnsmasq.sh delegates the fail-closed decision instead of parsing flags inline" {
    # Expansion-form needles so comments naming the flags cannot fake-satisfy this.
    run grep -Fn '${SINKHOLE_FAST_FAIL' "$PROJECT_DIR/linux/lib/dns-dnsmasq.sh"
    [ "$status" -ne 0 ]

    run grep -Fn '${IPV6_FIREWALL_ENABLED' "$PROJECT_DIR/linux/lib/dns-dnsmasq.sh"
    [ "$status" -ne 0 ]

    run grep -Fn 'ipv6_sinkhole_fail_closed' "$PROJECT_DIR/linux/lib/dns-dnsmasq.sh"
    [ "$status" -eq 0 ]

    run grep -Fn 'ipv6_sinkhole_fail_closed' "$PROJECT_DIR/linux/lib/firewall-rule-helpers.sh"
    [ "$status" -eq 0 ]
}
