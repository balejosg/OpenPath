#!/bin/bash

# OpenPath - Strict Internet Access Control
# Copyright (C) 2025 OpenPath Authors
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU Affero General Public License as
# published by the Free Software Foundation, either version 3 of the
# License, or (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU Affero General Public License for more details.
#
# You should have received a copy of the GNU Affero General Public License
# along with this program.  If not, see <https://www.gnu.org/licenses/>.

################################################################################
# uninstall.sh - OpenPath DNS uninstaller
# Part of the OpenPath DNS system
#
# Corregido para:
# - Restaurar systemd-resolved correctamente (socket primero)
# - Usar gateway como DNS fallback (para portales cautivos)
# - Compatibilidad con versiones anteriores sin backups
# - Verificar DNS funcional antes de terminar
################################################################################

set -eo pipefail

# Verify root
if [ "$EUID" -ne 0 ]; then
    echo "ERROR: Run with sudo"
    exit 1
fi

echo "======================================================"
echo "  Uninstall: dnsmasq URL Whitelist System"
echo "======================================================"
echo ""

# Confirmar (skip si --auto-yes o --unattended o -y)
if [[ ! "${1:-}" =~ ^(--auto-yes|--unattended|-y)$ ]]; then
    read -p "Uninstall the system? (y/N): " confirm
    [[ ! "$confirm" =~ ^[Yy]$ ]] && { echo "Canceled"; exit 0; }
fi

echo ""
echo "[1/7] Stopping services..."
systemctl stop openpath-dnsmasq.timer 2>/dev/null || true
systemctl stop openpath-agent-update.timer 2>/dev/null || true
systemctl stop dnsmasq-watchdog.timer 2>/dev/null || true
systemctl stop captive-portal-detector.service 2>/dev/null || true
systemctl stop openpath-runtime-dependency-apply.path 2>/dev/null || true
# Stop the regenerator SERVICES too (not just their timer/path triggers): an
# in-flight watchdog or runtime-dependency-apply run can otherwise finish and
# rewrite /etc/dnsmasq.d/openpath.conf after we remove it below (a uninstall
# race that surfaces on ubuntu-24.04 systemd timing).
systemctl stop dnsmasq-watchdog.service 2>/dev/null || true
systemctl stop openpath-runtime-dependency-apply.service 2>/dev/null || true
systemctl stop dnsmasq 2>/dev/null || true
systemctl disable dnsmasq 2>/dev/null || true

# Wait for dnsmasq to stop (max 5 seconds)
echo "  Waiting for dnsmasq to stop..."
for _ in $(seq 1 5); do
    if ! pgrep -x dnsmasq >/dev/null 2>&1; then
        break
    fi
    sleep 1
done

if pgrep -x dnsmasq >/dev/null 2>&1; then
    echo "  Killing residual dnsmasq processes (SIGKILL)..."
    pkill -9 dnsmasq 2>/dev/null || true
fi

# Verify port 53 is free
if ss -tulpn 2>/dev/null | grep -q ":53 "; then
    echo "  ⚠ Port 53 still in use, trying to release it..."
    fuser -k 53/udp 2>/dev/null || true
    fuser -k 53/tcp 2>/dev/null || true
    # Brief wait for the kernel to release the socket.
    sleep 0.5
fi

echo "[2/7] Disabling services..."
systemctl disable openpath-dnsmasq.timer 2>/dev/null || true
systemctl disable openpath-agent-update.timer 2>/dev/null || true
systemctl disable dnsmasq-watchdog.timer 2>/dev/null || true
systemctl disable captive-portal-detector.service 2>/dev/null || true
systemctl disable openpath-runtime-dependency-apply.path 2>/dev/null || true

echo "[3/7] Removing systemd services..."
rm -f /etc/systemd/system/openpath-dnsmasq.service
rm -f /etc/systemd/system/openpath-dnsmasq.timer
rm -f /etc/systemd/system/openpath-agent-update.service
rm -f /etc/systemd/system/openpath-agent-update.timer
rm -f /etc/systemd/system/openpath-runtime-dependency-apply.service
rm -f /etc/systemd/system/openpath-runtime-dependency-apply.path
rm -f /etc/systemd/system/dnsmasq-watchdog.service
rm -f /etc/systemd/system/dnsmasq-watchdog.timer
rm -f /etc/systemd/system/captive-portal-detector.service
rm -rf /etc/systemd/system/dnsmasq.service.d
systemctl daemon-reload

echo "[4/7] Restoring DNS..."

# Unprotect resolv.conf
chattr -i /etc/resolv.conf 2>/dev/null || true

# Detect gateway for captive-portal compatible fallback.
GATEWAY=$(ip route | grep default | awk '{print $3}' | head -1)
echo "  Detected gateway: ${GATEWAY:-none}"

# Resolve fallback DNS (gateway first, then external DNS).
get_fallback_dns() {
    local dns=""
    # Try NetworkManager DNS first.
    if command -v nmcli >/dev/null 2>&1; then
        dns=$(nmcli dev show 2>/dev/null | grep -i "IP4.DNS\[1\]" | awk '{print $2}' | head -1)
    fi
    # If NetworkManager has no DNS, use the gateway for captive portals.
    if [ -z "$dns" ] && [ -n "$GATEWAY" ]; then
        dns="$GATEWAY"
    fi
    # Final fallback.
    [ -z "$dns" ] && dns="8.8.8.8"
    echo "$dns"
}

# Step 1: Restore systemd-resolved first, before changing resolv.conf.
echo "  Restoring systemd-resolved..."

# Unmask in case older versions masked it.
systemctl unmask systemd-resolved.socket 2>/dev/null || true
systemctl unmask systemd-resolved 2>/dev/null || true

# Enable socket first, then service.
systemctl enable systemd-resolved.socket 2>/dev/null || true
systemctl enable systemd-resolved 2>/dev/null || true

# Start socket first, then service.
systemctl start systemd-resolved.socket 2>/dev/null || true
systemctl start systemd-resolved 2>/dev/null || true

# Wait for systemd-resolved to create the stub (max 10 seconds).
echo "  Waiting for systemd-resolved..."
for _ in $(seq 1 10); do
    if [ -f /run/systemd/resolve/stub-resolv.conf ]; then
        echo "  ✓ systemd-resolved active"
        break
    fi
    sleep 1
done

# Step 2: Restore resolv.conf.
rm -f /etc/resolv.conf 2>/dev/null || true

if systemctl is-active --quiet systemd-resolved; then
    # systemd-resolved works: use its stub.
    echo "  Using systemd-resolved stub..."
    if ! ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf 2>/dev/null; then
        echo "  ⚠ Could not recreate /etc/resolv.conf symlink; copying stub..."
        cp /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
    fi
elif [ -f /var/lib/openpath/resolv.conf.symlink.backup ]; then
    # Try restoring symlink backup.
    target=$(cat /var/lib/openpath/resolv.conf.symlink.backup)
    if [ -f "$target" ]; then
        echo "  Restoring symlink from backup..."
        ln -sf "$target" /etc/resolv.conf
    else
        # Target does not exist; create resolv.conf with fallback DNS.
        echo "  Backup target does not exist; using gateway DNS..."
        FALLBACK_DNS=$(get_fallback_dns)
        cat > /etc/resolv.conf << EOF
# Restored by uninstall.sh (fallback)
nameserver $FALLBACK_DNS
nameserver 8.8.8.8
EOF
    fi
elif [ -f /var/lib/openpath/resolv.conf.backup ]; then
    # Restore file backup.
    echo "  Restoring resolv.conf from backup..."
    cp /var/lib/openpath/resolv.conf.backup /etc/resolv.conf
else
    # No backups: create resolv.conf with fallback DNS.
    # Use gateway as primary DNS for captive portal compatibility.
    echo "  No backups found; using gateway/DHCP DNS..."
    FALLBACK_DNS=$(get_fallback_dns)
    cat > /etc/resolv.conf << EOF
# Restored by uninstall.sh (no previous backup)
# Using gateway/DHCP DNS for captive portal compatibility
nameserver $FALLBACK_DNS
nameserver 8.8.8.8
EOF
fi

echo "[5/7] Cleaning firewall..."
iptables -F OUTPUT 2>/dev/null || true
iptables -P OUTPUT ACCEPT 2>/dev/null || true
ipset destroy openpath-doh-block 2>/dev/null || true
rm -f /etc/iptables/openpath-ipsets.v4 2>/dev/null || true
iptables-save > /etc/iptables/rules.v4 2>/dev/null || true

echo "[6/7] Removing files..."
CHROMIUM_EXT_ID=""
if [ -f /var/lib/openpath/browser-extension/extension-id ]; then
    CHROMIUM_EXT_ID=$(cat /var/lib/openpath/browser-extension/extension-id 2>/dev/null || true)
fi

rm -f /usr/local/bin/openpath-update.sh
rm -f /usr/local/bin/openpath-runtime-dependency-apply.sh
rm -f /usr/local/bin/dnsmasq-watchdog.sh
rm -f /usr/local/bin/dnsmasq-init-resolv.sh
rm -f /usr/local/bin/captive-portal-detector.sh
rm -f /usr/local/bin/openpath
rm -f /usr/local/bin/openpath-browser-setup.sh
rm -f /usr/local/bin/openpath-self-update.sh
rm -f /usr/local/bin/openpath-agent-update.sh
rm -rf /usr/local/lib/openpath
rm -f /etc/dnsmasq.d/openpath.conf
rm -rf /var/lib/openpath/runtime-dependency-queue
rm -rf /var/lib/openpath/runtime-dependency-rejected
rm -f /var/lib/openpath/runtime-dependency-overlay.json
rm -rf /var/lib/openpath
rm -f /var/log/openpath.log
rm -f /var/log/captive-portal-detector.log
rm -f /etc/tmpfiles.d/openpath-dnsmasq.conf
rm -f /etc/logrotate.d/openpath-dnsmasq
rm -rf /run/dnsmasq
rm -f /etc/sudoers.d/openpath
rm -f /etc/NetworkManager/dispatcher.d/99-openpath-captive-check

# Clean browser policies.
if [ -d /etc/firefox/policies ]; then
    echo '{"policies": {}}' > /etc/firefox/policies/policies.json 2>/dev/null || true
fi
rm -f /etc/chromium/policies/managed/url-whitelist.json 2>/dev/null || true
rm -f /etc/chromium-browser/policies/managed/url-whitelist.json 2>/dev/null || true
rm -f /etc/opt/chrome/policies/managed/url-whitelist.json 2>/dev/null || true

# Remove Firefox extension.
echo "  Removing Firefox extension..."
rm -rf "/usr/share/mozilla/extensions/{ec8030f7-c20a-464f-9b0e-13a3a9e97384}/openpath-block-monitor@openpath" 2>/dev/null || true
rm -rf "/usr/share/mozilla/extensions/{ec8030f7-c20a-464f-9b0e-13a3a9e97384}/monitor-bloqueos@whitelist-system" 2>/dev/null || true
rm -f /usr/lib/mozilla/native-messaging-hosts/whitelist_native_host.json 2>/dev/null || true
rm -f /etc/chromium/native-messaging-hosts/openpath_native_host.json 2>/dev/null || true
rm -f /etc/opt/chrome/native-messaging-hosts/openpath_native_host.json 2>/dev/null || true
rm -f /etc/opt/edge/native-messaging-hosts/openpath_native_host.json 2>/dev/null || true

if [ -n "$CHROMIUM_EXT_ID" ]; then
    rm -f "/usr/share/google-chrome/extensions/$CHROMIUM_EXT_ID.json" 2>/dev/null || true
    rm -f "/usr/share/microsoft-edge/extensions/$CHROMIUM_EXT_ID.json" 2>/dev/null || true
fi

# Remove Firefox autoconfig and restore signature verification.
for firefox_dir in /usr/lib/firefox-esr /usr/lib/firefox /opt/firefox; do
    if [ -d "$firefox_dir" ]; then
        rm -f "$firefox_dir/defaults/pref/autoconfig.js" 2>/dev/null || true
        rm -f "$firefox_dir/mozilla.cfg" 2>/dev/null || true
    fi
done

# Remove Mozilla PPA APT preferences.
rm -f /etc/apt/preferences.d/mozilla-firefox 2>/dev/null || true

echo ""
echo "[7/7] Checking connectivity..."

# Detect captive portal.
detect_captive_portal() {
    # Verify whether the gateway is reachable.
    if [ -n "$GATEWAY" ] && ping -c 1 -W 2 "$GATEWAY" >/dev/null 2>&1; then
        # Try captive portal detection via HTTP.
        local response
        response=$(curl -s -m 5 -o /dev/null -w "%{http_code}" "http://detectportal.firefox.com/success.txt" 2>/dev/null)
        # 200 = no portal/authenticated; redirects or other responses = captive portal.
        if [ "$response" = "200" ]; then
            return 1
        elif [ -n "$response" ]; then
            return 0
        fi
        # No HTTP response but reachable gateway: probably captive portal blocking.
        return 0
    fi
    return 1
}

# Connectivity test.
CONN_OK=false
DNS_OK=false
CAPTIVE_PORTAL=false

if ping -c 2 8.8.8.8 >/dev/null 2>&1; then
    echo "  ✓ IP connectivity: OK"
    CONN_OK=true
else
    # No external connectivity; check for captive portal.
    if [ -n "$GATEWAY" ] && ping -c 1 -W 2 "$GATEWAY" >/dev/null 2>&1; then
        echo "  ℹ Gateway reachable ($GATEWAY), but external Internet is unavailable"
        if detect_captive_portal; then
            echo "  ℹ Captive portal detected"
            CAPTIVE_PORTAL=true
        else
            echo "  ✗ No external IP connectivity"
        fi
    else
        echo "  ✗ No network connectivity"
    fi
fi

# DNS test with multiple methods.
if timeout 5 nslookup google.com >/dev/null 2>&1; then
    echo "  ✓ DNS: OK"
    DNS_OK=true
elif timeout 5 host google.com >/dev/null 2>&1; then
    echo "  ✓ DNS: OK (via host)"
    DNS_OK=true
elif timeout 5 dig google.com +short >/dev/null 2>&1; then
    echo "  ✓ DNS: OK (via dig)"
    DNS_OK=true
else
    echo "  ✗ DNS: FAILED"
fi

# If DNS fails but connectivity exists, try repair.
if [ "$CONN_OK" = true ] && [ "$DNS_OK" = false ]; then
    echo ""
    echo "  Attempting DNS repair..."

    # Retry systemd-resolved.
    systemctl restart systemd-resolved 2>/dev/null || true
    sleep 2

    if systemctl is-active --quiet systemd-resolved; then
        # Force stub usage.
        rm -f /etc/resolv.conf 2>/dev/null || true
        ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
        echo "  Reconfigured to systemd-resolved"
    else
        # systemd-resolved is unavailable; use gateway directly.
        FALLBACK_DNS=$(get_fallback_dns)
        cat > /etc/resolv.conf << EOF
nameserver $FALLBACK_DNS
nameserver 8.8.8.8
EOF
        echo "  Reconfigured DNS: $FALLBACK_DNS"
    fi

    # Verify again.
    sleep 1
    if timeout 5 nslookup google.com >/dev/null 2>&1; then
        echo "  ✓ DNS repaired successfully"
        DNS_OK=true
    else
        echo "  ⚠ DNS still has problems - a restart may be required"
    fi
fi

# Final sweep: the [4/7] systemd-resolved restart can wake a regenerator that
# rewrites the dnsmasq config after the earlier removal, so remove it once more
# now that every service and trigger is stopped.
rm -f /etc/dnsmasq.d/openpath.conf 2>/dev/null || true

echo ""
echo "======================================================"
echo "  ✓ UNINSTALL COMPLETED"
echo "======================================================"
echo ""

if [ "$CAPTIVE_PORTAL" = true ]; then
    echo "System restored successfully."
    echo ""
    echo "Captive portal detected - DNS configured to work after authentication."
    echo "→ Open a browser to authenticate on the Wi-Fi network."
elif [ "$CONN_OK" = true ] && [ "$DNS_OK" = true ]; then
    echo "System restored successfully."
elif [ "$CONN_OK" = true ]; then
    echo "⚠ Connectivity OK but DNS may require a system restart."
else
    echo "⚠ No network connectivity detected."
    echo "  Check the network connection."
fi
echo ""
