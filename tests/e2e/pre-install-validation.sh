#!/bin/bash
################################################################################
# pre-install-validation.sh - Pre-installation validation tests
# 
# Validates that all required files, directories, and permissions are present
# BEFORE attempting installation. This catches packaging/release issues early.
#
# Usage: ./tests/e2e/pre-install-validation.sh
################################################################################

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Counters
PASSED=0
FAILED=0
WARNINGS=0

# Get script directory and project root
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
MANIFEST_DIR="$SCRIPT_DIR/validation"

# ============== Helper Functions ==============

test_pass() {
    echo -e "  ${GREEN}✓${NC} $1"
    PASSED=$((PASSED + 1))
}

test_fail() {
    echo -e "  ${RED}✗${NC} $1"
    FAILED=$((FAILED + 1))
}

test_warn() {
    echo -e "  ${YELLOW}⚠${NC} $1"
    WARNINGS=$((WARNINGS + 1))
}

test_section() {
    echo ""
    echo -e "${BLUE}[$1]${NC} $2"
}

read_manifest_entries() {
    local file="$1"

    if [ ! -f "$file" ]; then
        test_fail "Manifest missing: ${file#$PROJECT_ROOT/}"
        return 0
    fi

    while IFS= read -r line || [ -n "$line" ]; do
        line="${line%$'\r'}"
        [[ -z "${line//[[:space:]]/}" ]] && continue
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        printf '%s\n' "$line"
    done < "$file"
}

# ============== Validation Tests ==============

test_file_permissions() {
    test_section "1/6" "Script execution permissions"

    while IFS= read -r entry; do
        local mode
        local script
        mode="${entry%%[[:space:]]*}"
        script="${entry#*[[:space:]]}"
        local script_path="$PROJECT_ROOT/$script"

        if [ -f "$script_path" ]; then
            if [ -x "$script_path" ]; then
                test_pass "$script has execute permission"
            else
                if [ "$mode" = "optional" ]; then
                    test_warn "$script missing execute permission (needs chmod +x)"
                else
                    test_fail "$script missing execute permission (needs chmod +x)"
                fi
            fi
        else
            if [ "$mode" = "optional" ]; then
                test_warn "$script not found (optional)"
            else
                test_fail "$script missing"
            fi
        fi
    done < <(read_manifest_entries "$MANIFEST_DIR/executables.txt")
    
    # Check lib scripts
    if [ -d "$PROJECT_ROOT/linux/lib" ]; then
        local lib_count=0
        for lib_script in "$PROJECT_ROOT"/linux/lib/*.sh; do
            if [ -f "$lib_script" ]; then
                lib_count=$((lib_count + 1))
            fi
        done

        # The exact number of modules can change over time.
        if [ "$lib_count" -gt 0 ]; then
            test_pass "Found $lib_count library scripts in linux/lib/"
        else
            test_fail "No library scripts found in linux/lib/"
        fi
    fi
}

test_required_directories() {
    test_section "2/6" "Required directory structure"

    while IFS= read -r entry; do
        local mode
        local dir
        mode="${entry%%[[:space:]]*}"
        dir="${entry#*[[:space:]]}"
        local dir_path="$PROJECT_ROOT/$dir"

        if [ -d "$dir_path" ]; then
            test_pass "Directory $dir exists"
        else
            if [ "$mode" = "optional" ]; then
                test_warn "Directory $dir missing (optional)"
            else
                test_fail "Directory $dir missing"
            fi
        fi
    done < <(read_manifest_entries "$MANIFEST_DIR/required-dirs.txt")
}

test_required_files() {
    test_section "3/6" "Critical installation files"

    while IFS= read -r entry; do
        local mode
        local file
        mode="${entry%%[[:space:]]*}"
        file="${entry#*[[:space:]]}"
        local file_path="$PROJECT_ROOT/$file"

        if [ -f "$file_path" ]; then
            test_pass "File $file exists"
        else
            if [ "$mode" = "optional" ]; then
                test_warn "File $file missing (optional)"
            else
                test_fail "File $file missing"
            fi
        fi
    done < <(read_manifest_entries "$MANIFEST_DIR/required-files.txt")
}

test_firefox_extension_structure() {
    test_section "4/6" "Firefox extension structure"
    
    local ext_dir="$PROJECT_ROOT/firefox-extension"
    
    # Check manifest version (2 or 3 are valid)
    if [ -f "$ext_dir/manifest.json" ]; then
        if grep -qE '"manifest_version": [23]' "$ext_dir/manifest.json"; then
            test_pass "manifest.json has valid manifest_version"
        else
            test_fail "manifest.json missing or invalid manifest_version"
        fi
        
        # Check extension ID
        if grep -q '"id":.*"openpath-block-monitor@openpath"' "$ext_dir/manifest.json"; then
            test_pass "Extension ID correctly set"
        else
            test_fail "Extension ID missing or incorrect"
        fi
    fi
    
    # Check icon files
    if [ -d "$ext_dir/icons" ]; then
        local icon_count
        icon_count=$(find "$ext_dir/icons" -type f \( -name "*.png" -o -name "*.svg" \) 2>/dev/null | wc -l)
        if [ "$icon_count" -gt 0 ]; then
            test_pass "Found $icon_count icon file(s)"
        else
            test_warn "No icon files found in firefox-extension/icons/"
        fi
    fi
    
    # Check native messaging host is executable
    if [ -f "$ext_dir/native/openpath-native-host.py" ]; then
        if head -1 "$ext_dir/native/openpath-native-host.py" | grep -q "^#!/usr/bin"; then
            test_pass "Native host has shebang"
        else
            test_warn "Native host missing shebang line"
        fi
    fi
}

test_release_tarball_simulation() {
    test_section "5/6" "Release tarball contents simulation"

    # Simulate what would be in the Linux release tarball
    local tarball_contents=()
    while IFS= read -r entry; do
        local item
        item="${entry#*[[:space:]]}"
        tarball_contents+=("$item")
    done < <(read_manifest_entries "$MANIFEST_DIR/tarball-contents.txt")
    
    echo -e "  ${BLUE}Checking if tarball would contain all required files...${NC}"
    
    local all_present=true
    for item in "${tarball_contents[@]}"; do
        local item_path="$PROJECT_ROOT/$item"
        if [ -e "$item_path" ]; then
            if [ -d "$item_path" ]; then
                local file_count
                file_count=$(find "$item_path" -type f 2>/dev/null | wc -l)
                test_pass "Directory $item ($file_count files)"
            else
                test_pass "File $item"
            fi
        else
            test_fail "Missing in tarball: $item"
            all_present=false
        fi
    done
    
    if [ "$all_present" = true ]; then
        test_pass "All required tarball contents present"
    else
        test_fail "Tarball would be incomplete"
    fi
    
    # Check that install.sh step 12 requirements are met
    if [ -d "$PROJECT_ROOT/firefox-extension" ]; then
        test_pass "firefox-extension/ available for install.sh step 12"
    else
        test_fail "firefox-extension/ missing - install.sh step 12 will fail"
    fi
}

test_installer_extension_paths() {
    test_section "6/6" "Firefox installer path consistency"

    local installer_runtime_steps="$PROJECT_ROOT/linux/lib/install-runtime-steps.sh"
    local asset_helper="$PROJECT_ROOT/linux/lib/firefox-extension-assets.sh"

    if grep -Fq 'stage_firefox_installation_bundle "$INSTALLER_SOURCE_DIR/firefox-extension" "$staged_ext_dir"' "$installer_runtime_steps"; then
        test_pass "installer delegates unpacked Firefox asset staging to the shared helper"
    else
        test_fail "installer does not call the shared Firefox asset staging helper"
    fi

    if grep -Fq 'dist/background.js|file|extension build artifact' "$asset_helper"; then
        test_pass "Firefox asset helper requires dist/background.js"
    else
        test_fail "Firefox asset helper does not require dist/background.js"
    fi

    if grep -Fq 'dist/popup.js|file|extension build artifact' "$asset_helper"; then
        test_pass "Firefox asset helper requires dist/popup.js"
    else
        test_fail "Firefox asset helper does not require dist/popup.js"
    fi

    if grep -Fq 'dist/lib|dir|extension build artifact directory' "$asset_helper"; then
        test_pass "Firefox asset helper requires dist/lib"
    else
        test_fail "Firefox asset helper does not require dist/lib"
    fi

    if grep -Fq 'blocked/blocked.html|file|extension blocked screen' "$asset_helper" && \
       grep -Fq 'blocked/blocked.css|file|extension blocked screen' "$asset_helper" && \
       grep -Fq 'blocked/blocked.js|file|extension blocked screen' "$asset_helper"; then
        test_pass "Firefox asset helper requires blocked screen assets"
    else
        test_fail "Firefox asset helper does not require blocked screen assets"
    fi

    if grep -Fq 'dist/config.js' "$asset_helper"; then
        test_fail "Firefox asset helper still references dist/config.js"
    else
        test_pass "Firefox asset helper no longer requires dist/config.js"
    fi

    if grep -q 'cp "\$ext_source/background.js"' "$installer_runtime_steps"; then
        test_fail "installer still references legacy root background.js"
    else
        test_pass "installer no longer references legacy root background.js"
    fi
}

# ============== Main ==============

main() {
    echo ""
    echo -e "${BLUE}═══════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}  Pre-Installation Validation Tests${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════${NC}"
    echo ""
    echo "Project root: $PROJECT_ROOT"
    
    test_file_permissions
    test_required_directories
    test_required_files
    test_firefox_extension_structure
    test_release_tarball_simulation
    test_installer_extension_paths
    
    # Summary
    echo ""
    echo -e "${BLUE}═══════════════════════════════════════════════════${NC}"
    echo -e "  Results: ${GREEN}$PASSED passed${NC}, ${YELLOW}$WARNINGS warnings${NC}, ${RED}$FAILED failed${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════${NC}"
    echo ""
    
    if [ "$FAILED" -gt 0 ]; then
        echo -e "${RED}✗ PRE-INSTALLATION VALIDATION FAILED${NC}"
        echo ""
        echo "These issues must be fixed before packaging/release:"
        echo "- Fix file permissions: chmod +x <file>"
        echo "- Add missing files/directories"
        echo "- Update release workflow to include all required files"
        exit 1
    elif [ "$WARNINGS" -gt 0 ]; then
        echo -e "${YELLOW}⚠ VALIDATION PASSED WITH WARNINGS${NC}"
        echo ""
        echo "Consider addressing warnings before release"
        exit 0
    else
        echo -e "${GREEN}✓ PRE-INSTALLATION VALIDATION PASSED${NC}"
        echo ""
        echo "All required files and permissions are present"
        exit 0
    fi
}

main "$@"
