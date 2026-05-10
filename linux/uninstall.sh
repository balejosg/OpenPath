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
# uninstall.sh - Desinstalador del sistema whitelist
# Parte del sistema dnsmasq URL Whitelist v3.5
#
# Corregido para:
# - Restaurar systemd-resolved correctamente (socket primero)
# - Usar gateway como DNS fallback (para portales cautivos)
# - Compatibilidad con versiones anteriores sin backups
# - Verificar DNS funcional antes de terminar
################################################################################

set -eo pipefail

# Verificar root
if [ "$EUID" -ne 0 ]; then
    echo "ERROR: Ejecutar con sudo"
    exit 1
fi

echo "======================================================"
echo "  Desinstalación: dnsmasq URL Whitelist System"
echo "======================================================"
echo ""

# Confirmar (skip si --auto-yes o --unattended o -y)
if [[ ! "${1:-}" =~ ^(--auto-yes|--unattended|-y)$ ]]; then
    read -p "¿Desinstalar el sistema? (y/N): " confirm
    [[ ! "$confirm" =~ ^[Yy]$ ]] && { echo "Cancelado"; exit 0; }
fi

echo ""
echo "[1/7] Deteniendo servicios..."
systemctl stop openpath-dnsmasq.timer 2>/dev/null || true
systemctl stop openpath-agent-update.timer 2>/dev/null || true
systemctl stop dnsmasq-watchdog.timer 2>/dev/null || true
systemctl stop captive-portal-detector.service 2>/dev/null || true
systemctl stop dnsmasq 2>/dev/null || true
systemctl disable dnsmasq 2>/dev/null || true

# Esperar a que dnsmasq se detenga (máx 5 segundos)
echo "  Esperando a que dnsmasq se detenga..."
for _ in $(seq 1 5); do
    if ! pgrep -x dnsmasq >/dev/null 2>&1; then
        break
    fi
    sleep 1
done

if pgrep -x dnsmasq >/dev/null 2>&1; then
    echo "  Matando procesos dnsmasq residuales (SIGKILL)..."
    pkill -9 dnsmasq 2>/dev/null || true
fi

# Verificar que el puerto 53 está libre
if ss -tulpn 2>/dev/null | grep -q ":53 "; then
    echo "  ⚠ Puerto 53 aún ocupado, intentando liberar..."
    fuser -k 53/udp 2>/dev/null || true
    fuser -k 53/tcp 2>/dev/null || true
    # Breve espera para que el kernel libere el socket
    sleep 0.5
fi

echo "[2/7] Deshabilitando servicios..."
systemctl disable openpath-dnsmasq.timer 2>/dev/null || true
systemctl disable openpath-agent-update.timer 2>/dev/null || true
systemctl disable dnsmasq-watchdog.timer 2>/dev/null || true
systemctl disable captive-portal-detector.service 2>/dev/null || true

echo "[3/7] Eliminando servicios systemd..."
rm -f /etc/systemd/system/openpath-dnsmasq.service
rm -f /etc/systemd/system/openpath-dnsmasq.timer
rm -f /etc/systemd/system/openpath-agent-update.service
rm -f /etc/systemd/system/openpath-agent-update.timer
rm -f /etc/systemd/system/dnsmasq-watchdog.service
rm -f /etc/systemd/system/dnsmasq-watchdog.timer
rm -f /etc/systemd/system/captive-portal-detector.service
rm -rf /etc/systemd/system/dnsmasq.service.d
systemctl daemon-reload

echo "[4/7] Restaurando DNS..."

# Desproteger resolv.conf
chattr -i /etc/resolv.conf 2>/dev/null || true

# Detectar gateway (necesario para fallback compatible con portales cautivos)
GATEWAY=$(ip route | grep default | awk '{print $3}' | head -1)
echo "  Gateway detectado: ${GATEWAY:-ninguno}"

# Función para obtener DNS inteligente (gateway primero, luego externos)
get_fallback_dns() {
    local dns=""
    # Intentar obtener DNS de NetworkManager
    if command -v nmcli >/dev/null 2>&1; then
        dns=$(nmcli dev show 2>/dev/null | grep -i "IP4.DNS\[1\]" | awk '{print $2}' | head -1)
    fi
    # Si no hay DNS de NM, usar gateway (funciona en portales cautivos)
    if [ -z "$dns" ] && [ -n "$GATEWAY" ]; then
        dns="$GATEWAY"
    fi
    # Fallback final
    [ -z "$dns" ] && dns="8.8.8.8"
    echo "$dns"
}

# PASO 1: Restaurar systemd-resolved PRIMERO (antes de tocar resolv.conf)
echo "  Restaurando systemd-resolved..."

# Desenmascar por si estaba enmascarado (versiones antiguas)
systemctl unmask systemd-resolved.socket 2>/dev/null || true
systemctl unmask systemd-resolved 2>/dev/null || true

# Habilitar socket PRIMERO, luego servicio
systemctl enable systemd-resolved.socket 2>/dev/null || true
systemctl enable systemd-resolved 2>/dev/null || true

# Iniciar socket PRIMERO, luego servicio
systemctl start systemd-resolved.socket 2>/dev/null || true
systemctl start systemd-resolved 2>/dev/null || true

# Esperar a que systemd-resolved cree el stub (máx 10 segundos)
echo "  Esperando a systemd-resolved..."
for _ in $(seq 1 10); do
    if [ -f /run/systemd/resolve/stub-resolv.conf ]; then
        echo "  ✓ systemd-resolved activo"
        break
    fi
    sleep 1
done

# PASO 2: Restaurar resolv.conf
rm -f /etc/resolv.conf 2>/dev/null || true

if systemctl is-active --quiet systemd-resolved; then
    # systemd-resolved funciona: usar su stub
    echo "  Usando systemd-resolved stub..."
    if ! ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf 2>/dev/null; then
        echo "  ⚠ No se pudo recrear el symlink de /etc/resolv.conf; copiando stub..."
        cp /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
    fi
elif [ -f /var/lib/openpath/resolv.conf.symlink.backup ]; then
    # Intentar restaurar backup de symlink
    target=$(cat /var/lib/openpath/resolv.conf.symlink.backup)
    if [ -f "$target" ]; then
        echo "  Restaurando symlink desde backup..."
        ln -sf "$target" /etc/resolv.conf
    else
        # El target no existe, crear resolv.conf con DNS inteligente
        echo "  Target del backup no existe, usando DNS del gateway..."
        FALLBACK_DNS=$(get_fallback_dns)
        cat > /etc/resolv.conf << EOF
# Restaurado por uninstall.sh (fallback)
nameserver $FALLBACK_DNS
nameserver 8.8.8.8
EOF
    fi
elif [ -f /var/lib/openpath/resolv.conf.backup ]; then
    # Restaurar backup de archivo
    echo "  Restaurando resolv.conf desde backup..."
    cp /var/lib/openpath/resolv.conf.backup /etc/resolv.conf
else
    # Sin backups: crear resolv.conf con DNS inteligente
    # Usar gateway como DNS primario (funciona en portales cautivos)
    echo "  Sin backups, usando DNS del gateway/DHCP..."
    FALLBACK_DNS=$(get_fallback_dns)
    cat > /etc/resolv.conf << EOF
# Restaurado por uninstall.sh (sin backup previo)
# Usando gateway/DHCP DNS para compatibilidad con portales cautivos
nameserver $FALLBACK_DNS
nameserver 8.8.8.8
EOF
fi

echo "[5/7] Limpiando firewall..."
iptables -F OUTPUT 2>/dev/null || true
iptables -P OUTPUT ACCEPT 2>/dev/null || true
iptables-save > /etc/iptables/rules.v4 2>/dev/null || true

echo "[6/7] Eliminando archivos..."
CHROMIUM_EXT_ID=""
if [ -f /var/lib/openpath/browser-extension/extension-id ]; then
    CHROMIUM_EXT_ID=$(cat /var/lib/openpath/browser-extension/extension-id 2>/dev/null || true)
fi

rm -f /usr/local/bin/openpath-update.sh
rm -f /usr/local/bin/dnsmasq-watchdog.sh
rm -f /usr/local/bin/dnsmasq-init-resolv.sh
rm -f /usr/local/bin/captive-portal-detector.sh
rm -f /usr/local/bin/openpath
rm -f /usr/local/bin/openpath-browser-setup.sh
rm -f /usr/local/bin/openpath-self-update.sh
rm -f /usr/local/bin/openpath-agent-update.sh
rm -rf /usr/local/lib/openpath
rm -f /etc/dnsmasq.d/openpath.conf
rm -rf /var/lib/openpath
rm -f /var/log/openpath.log
rm -f /var/log/captive-portal-detector.log
rm -f /etc/tmpfiles.d/openpath-dnsmasq.conf
rm -f /etc/logrotate.d/openpath-dnsmasq
rm -rf /run/dnsmasq
rm -f /etc/sudoers.d/openpath
rm -f /etc/NetworkManager/dispatcher.d/99-openpath-captive-check

# Limpiar políticas de navegadores
if [ -d /etc/firefox/policies ]; then
    echo '{"policies": {}}' > /etc/firefox/policies/policies.json 2>/dev/null || true
fi
rm -f /etc/chromium/policies/managed/url-whitelist.json 2>/dev/null || true
rm -f /etc/chromium-browser/policies/managed/url-whitelist.json 2>/dev/null || true
rm -f /etc/opt/chrome/policies/managed/url-whitelist.json 2>/dev/null || true

# Eliminar extensión de Firefox
echo "  Eliminando extensión Firefox..."
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

# Eliminar autoconfig de Firefox (restaurar verificación de firmas)
for firefox_dir in /usr/lib/firefox-esr /usr/lib/firefox /opt/firefox; do
    if [ -d "$firefox_dir" ]; then
        rm -f "$firefox_dir/defaults/pref/autoconfig.js" 2>/dev/null || true
        rm -f "$firefox_dir/mozilla.cfg" 2>/dev/null || true
    fi
done

# Eliminar preferencias de APT para Mozilla PPA
rm -f /etc/apt/preferences.d/mozilla-firefox 2>/dev/null || true

echo ""
echo "[7/7] Verificando conectividad..."

# Función para detectar portal cautivo
detect_captive_portal() {
    # Verificar si hay gateway accesible
    if [ -n "$GATEWAY" ] && ping -c 1 -W 2 "$GATEWAY" >/dev/null 2>&1; then
        # Intentar detectar portal cautivo via HTTP
        local response
        response=$(curl -s -m 5 -o /dev/null -w "%{http_code}" "http://detectportal.firefox.com/success.txt" 2>/dev/null)
        # 200 = sin portal (autenticado), 302/301/otros = portal cautivo
        if [ "$response" = "200" ]; then
            return 1  # No hay portal cautivo (o ya autenticado)
        elif [ -n "$response" ]; then
            return 0  # Portal cautivo detectado
        fi
        # Sin respuesta HTTP pero gateway accesible = probablemente portal cautivo bloqueando
        return 0
    fi
    return 1  # No se puede determinar (sin gateway)
}

# Test de conectividad
CONN_OK=false
DNS_OK=false
CAPTIVE_PORTAL=false

if ping -c 2 8.8.8.8 >/dev/null 2>&1; then
    echo "  ✓ Conectividad IP: OK"
    CONN_OK=true
else
    # Sin conectividad externa - verificar si es portal cautivo
    if [ -n "$GATEWAY" ] && ping -c 1 -W 2 "$GATEWAY" >/dev/null 2>&1; then
        echo "  ℹ Gateway accesible ($GATEWAY) pero sin Internet externo"
        if detect_captive_portal; then
            echo "  ℹ Portal cautivo detectado"
            CAPTIVE_PORTAL=true
        else
            echo "  ✗ Sin conectividad IP externa"
        fi
    else
        echo "  ✗ Sin conectividad de red"
    fi
fi

# Test DNS con múltiples métodos
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
    echo "  ✗ DNS: FALLO"
fi

# Si DNS falla pero hay conectividad, intentar reparación
if [ "$CONN_OK" = true ] && [ "$DNS_OK" = false ]; then
    echo ""
    echo "  Intentando reparación de DNS..."

    # Reintentar systemd-resolved
    systemctl restart systemd-resolved 2>/dev/null || true
    sleep 2

    if systemctl is-active --quiet systemd-resolved; then
        # Forzar uso del stub
        rm -f /etc/resolv.conf 2>/dev/null || true
        ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
        echo "  Reconfigurado a systemd-resolved"
    else
        # systemd-resolved no funciona, usar gateway directamente
        FALLBACK_DNS=$(get_fallback_dns)
        cat > /etc/resolv.conf << EOF
nameserver $FALLBACK_DNS
nameserver 8.8.8.8
EOF
        echo "  Reconfigurado a DNS: $FALLBACK_DNS"
    fi

    # Verificar de nuevo
    sleep 1
    if timeout 5 nslookup google.com >/dev/null 2>&1; then
        echo "  ✓ DNS reparado correctamente"
        DNS_OK=true
    else
        echo "  ⚠ DNS aún con problemas - puede requerir reinicio"
    fi
fi

echo ""
echo "======================================================"
echo "  ✓ DESINSTALACIÓN COMPLETADA"
echo "======================================================"
echo ""

if [ "$CAPTIVE_PORTAL" = true ]; then
    echo "Sistema restaurado correctamente."
    echo ""
    echo "Portal cautivo detectado - DNS configurado para funcionar tras autenticación."
    echo "→ Abre un navegador para autenticarte en la red WiFi."
elif [ "$CONN_OK" = true ] && [ "$DNS_OK" = true ]; then
    echo "Sistema restaurado correctamente."
elif [ "$CONN_OK" = true ]; then
    echo "⚠ Conectividad OK pero DNS puede necesitar reinicio del sistema."
else
    echo "⚠ Sin conectividad de red detectada."
    echo "  Verifica la conexión de red."
fi
echo ""
