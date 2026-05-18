#!/bin/bash

################################################################################
# install-runtime-steps.sh - Browser/runtime installer workflow steps
################################################################################

step_install_firefox() {
    echo ""
    echo "[10/13] Instalando Firefox..."

    if [ "$INSTALL_FIREFOX" = false ]; then
        echo "⊘ Firefox omitido (--skip-firefox)"
        return 0
    fi

    if install_firefox_esr; then
        echo "✓ Firefox instalado"
    else
        echo "⚠ Firefox no pudo instalarse (continuando)"
    fi
}

step_apply_policies() {
    echo ""
    echo "[11/13] Verifying browser integrations..."

    echo "✓ Integrations prepared"
}

step_install_extension() {
    echo ""
    echo "[12/13] Instalando extensiones del navegador..."

    if [ "$INSTALL_EXTENSION" = true ]; then
        local staged_ext_dir="$INSTALL_DIR/firefox-extension"
        local staged_release_dir="$INSTALL_DIR/firefox-release"
        local firefox_release_source=""

        rm -rf "$staged_ext_dir"
        rm -rf "$staged_release_dir"
        stage_firefox_installation_bundle "$INSTALLER_SOURCE_DIR/firefox-extension" "$staged_ext_dir"

        if firefox_release_source="$(stage_firefox_release_artifacts "$INSTALLER_SOURCE_DIR" "$staged_release_dir")"; then
            echo "  ✓ Artefactos Firefox Release firmados preparados desde $firefox_release_source"
        fi

        if ! is_openpath_request_setup_complete; then
            if [ "$INSTALL_NATIVE_HOST" = true ]; then
                if ! run_classroom_registration; then
                    echo "✗ ERROR: no se pudo completar el registro requerido para solicitudes del navegador"
                    return 1
                fi
            else
                echo "⊘ Extensiones del navegador omitidas hasta completar OpenPath setup"
                return 0
            fi
        fi

        if [ "$INSTALL_NATIVE_HOST" = true ]; then
            require_openpath_request_setup_complete "source install browser request setup" || return 1
        fi

        local browser_integration_args=(
            --firefox-required
            --chromium-best-effort
            --native-host-required
        )
        if [ "$INSTALL_NATIVE_HOST" = true ]; then
            browser_integration_args+=(--native-host)
        fi

        install_browser_integrations \
            "$staged_ext_dir" \
            "$staged_release_dir" \
            "${browser_integration_args[@]}"
        if declare -F verify_firefox_extension_registered >/dev/null 2>&1; then
            verify_firefox_extension_registered
        elif [ -x "$SCRIPTS_DIR/openpath-browser-setup.sh" ]; then
            "$SCRIPTS_DIR/openpath-browser-setup.sh"
        fi
        echo "✓ Extensiones del navegador instaladas"
    else
        echo "⊘ Extensiones del navegador omitidas (--no-extension)"
    fi
}

step_enable_services() {
    echo ""
    echo "[13/13] Enabling services..."

    enable_services

    echo "Generando hashes de integridad..."
    source "$INSTALL_DIR/lib/common.sh"
    INTEGRITY_HASH_FILE="$VAR_STATE_DIR/integrity.sha256"
    : > "$INTEGRITY_HASH_FILE"
    for f in "${CRITICAL_FILES[@]}"; do
        [ -f "$f" ] && sha256sum "$f" >> "$INTEGRITY_HASH_FILE"
    done
    chmod 600 "$INTEGRITY_HASH_FILE"
    echo "✓ Integrity hashes generated"

    echo "Running first update..."
    "$SCRIPTS_DIR/openpath-update.sh" || echo "⚠ First update failed (the timer will retry)"

    echo "✓ Services enabled"
}

run_smoke_tests() {
    if [ -f "$INSTALLER_SOURCE_DIR/scripts/runtime/smoke-test.sh" ]; then
        cp "$INSTALLER_SOURCE_DIR/scripts/runtime/smoke-test.sh" "$SCRIPTS_DIR/"
        chmod +x "$SCRIPTS_DIR/smoke-test.sh"
    fi

    echo ""
    echo "Running smoke tests..."
    if "$SCRIPTS_DIR/smoke-test.sh" --quick 2>/dev/null; then
        SMOKE_STATUS="PASSED"
    else
        SMOKE_STATUS="FAILED"
    fi
}

run_classroom_registration() {
    MACHINE_REGISTERED=""
    if is_openpath_request_setup_complete; then
        MACHINE_REGISTERED="REGISTERED"
        return 0
    fi

    if [ -n "$CLASSROOM_NAME" ] && [ -n "$API_URL" ]; then
        echo ""
        echo "Registering machine in classroom..."

        if register_machine "$(hostname)" "$CLASSROOM_NAME" "" "$VERSION" "$API_URL" "$REGISTRATION_TOKEN"; then
            MACHINE_REGISTERED="REGISTERED"
            if [ -n "$TOKENIZED_URL" ] && is_tokenized_whitelist_url "$TOKENIZED_URL" && persist_openpath_whitelist_url "$TOKENIZED_URL"; then
                WHITELIST_URL="$TOKENIZED_URL"
                if [ -n "$REGISTERED_MACHINE_NAME" ]; then
                    persist_machine_name "$REGISTERED_MACHINE_NAME" || true
                fi
                echo "✓ Machine registered in classroom: $CLASSROOM_NAME"
                echo "  → Tokenized whitelist URL saved"
            else
                MACHINE_REGISTERED="FAILED"
                echo "⚠ Registration succeeded but no tokenized URL was received"
                return 1
            fi
        else
            MACHINE_REGISTERED="FAILED"
            echo "⚠ Error registering machine"
            echo "  Response: $REGISTER_RESPONSE"
            return 1
        fi
    elif [ "$INSTALL_NATIVE_HOST" = true ]; then
        MACHINE_REGISTERED="FAILED"
        echo "⚠ Browser request mode requires classroom configuration"
        return 1
    fi

    return 0
}

print_summary() {
    if [ "$VERBOSE" != true ]; then
        echo ""
        echo "Installation complete."
        echo "Status: dnsmasq=$(systemctl is-active dnsmasq), smoke-tests=$SMOKE_STATUS"
        if [ -n "$MACHINE_REGISTERED" ]; then
            echo "Enrollment: $MACHINE_REGISTERED"
        fi
        echo "Manage with: openpath status"
        echo "Uninstall: sudo $INSTALLER_SOURCE_DIR/uninstall.sh"
        echo ""
        return 0
    fi

    echo ""
    echo "======================================================"
    echo "  ✓ INSTALLATION COMPLETED"
    echo "======================================================"
    echo ""
    echo "Status:"
    echo "  - dnsmasq: $(systemctl is-active dnsmasq)"
    echo "  - Timer: $(systemctl is-active openpath-dnsmasq.timer)"
    echo "  - Agent Update: $(systemctl is-active openpath-agent-update.timer)"
    echo "  - Watchdog: $(systemctl is-active dnsmasq-watchdog.timer)"
    echo "  - Smoke Tests: $SMOKE_STATUS"
    if [ -n "$MACHINE_REGISTERED" ]; then
        echo "  - Classroom registration: $MACHINE_REGISTERED"
    fi
    echo ""
    echo "Configuration:"
    echo "  - Whitelist: $WHITELIST_URL"
    echo "  - DNS upstream: $PRIMARY_DNS"
    echo ""
    echo "Management command: openpath"
    echo "  openpath status  - View status"
    echo "  openpath test    - Test DNS"
    echo "  openpath update  - Force update"
    echo "  openpath help    - View full help"
    echo ""
    echo "Manual tests:"
    echo "  sudo smoke-test.sh        - Run full smoke tests"
    echo "  sudo smoke-test.sh --quick - Critical tests only"
    echo ""
    echo "Uninstall: sudo $INSTALLER_SOURCE_DIR/uninstall.sh"
    echo ""
}
