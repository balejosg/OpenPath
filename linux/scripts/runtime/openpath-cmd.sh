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
# openpath - Comando unificado de gestión
# Parte del sistema OpenPath DNS
################################################################################

# Cargar librerías
INSTALL_DIR="/usr/local/lib/openpath"
source "$INSTALL_DIR/lib/common.sh" 2>/dev/null || {
    echo "ERROR: Sistema no instalado correctamente"
    exit 1
}
if ! load_libraries; then
    echo "ERROR: Missing required OpenPath libraries"
    exit 1
fi

# Colores
# shellcheck disable=SC2034 # Used by sourced runtime CLI command modules.
RED='\033[0;31m'
# shellcheck disable=SC2034 # Used by sourced runtime CLI command modules.
GREEN='\033[0;32m'
# shellcheck disable=SC2034 # Used by sourced runtime CLI command modules.
YELLOW='\033[1;33m'
# shellcheck disable=SC2034 # Used by sourced runtime CLI command modules.
BLUE='\033[0;34m'
NC='\033[0m'

# Comandos de solo lectura que necesitan leer estado protegido y se permiten
# sin contraseña via sudoers.
READ_ONLY_ROOT_COMMANDS="status test check health domains log logs doctor"

# Comandos de escritura que requieren root (estos pedirán contraseña si no es root).
ROOT_COMMANDS="update force enable disable restart rotate-token enroll setup self-update"

# Auto-elevar a root si el comando lo requiere
auto_elevate() {
    local cmd="${1:-status}"
    if [[ " $READ_ONLY_ROOT_COMMANDS " =~ \ $cmd\  ]] && [ "$EUID" -ne 0 ]; then
        if [ "$#" -eq 0 ]; then
            exec sudo -n "$0" status
        fi
        exec sudo -n "$0" "$@"
    fi

    if [[ " $ROOT_COMMANDS " =~ \ $cmd\  ]] && [ "$EUID" -ne 0 ]; then
        exec sudo "$0" "$@"
    fi
}

# Llamar auto-elevación con los argumentos originales
auto_elevate "$@"

# shellcheck source=linux/lib/runtime-cli.sh
source "$INSTALL_DIR/lib/runtime-cli.sh" 2>/dev/null || {
    echo "ERROR: Missing OpenPath runtime CLI library"
    exit 1
}

# Procesar comando
case "${1:-status}" in
    status)     cmd_status ;;
    update)     cmd_update ;;
    test)       cmd_test ;;
    logs)       cmd_logs ;;
    log)        cmd_log "$2" ;;
    domains)    cmd_domains "$2" ;;
    check)      cmd_check "$2" ;;
    health)     cmd_health ;;
    doctor)     shift; cmd_doctor "$@" ;;
    force)      cmd_force ;;
    enable)     cmd_enable ;;
    disable)    cmd_disable ;;
    restart)    cmd_restart ;;
    setup)      shift; cmd_setup "$@" ;;
    rotate-token) cmd_rotate_token ;;
    enroll)     shift; cmd_enroll "$@" ;;
    self-update) shift; /usr/local/bin/openpath-agent-update.sh "$@" ;;
    help|--help|-h) cmd_help ;;
    *)
        echo -e "${RED}Comando desconocido: $1${NC}"
        cmd_help
        exit 1
        ;;
esac
