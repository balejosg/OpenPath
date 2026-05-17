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
# build-xpi.sh - Empaqueta la extensión como archivo XPI
# Parte del sistema Monitor de Bloqueos de Red
################################################################################

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="$SCRIPT_DIR/build"
XPI_NAME="monitor-bloqueos-red"

# Colores
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${BLUE}Empaquetando extensión Firefox...${NC}"
echo ""

# Leer versión del manifest
VERSION=$(grep '"version"' "$SCRIPT_DIR/manifest.json" | head -1 | sed 's/.*"version".*"\([^"]*\)".*/\1/')
echo "  Versión: $VERSION"

# Crear directorio de build
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

# Copiar archivos necesarios
echo "  → Copiando archivos..."

cp "$SCRIPT_DIR/manifest.json" "$BUILD_DIR/"
cp "$SCRIPT_DIR/PRIVACY.md" "$BUILD_DIR/"
cp -r "$SCRIPT_DIR/_locales" "$BUILD_DIR/"
cp -r "$SCRIPT_DIR/popup" "$BUILD_DIR/"
cp -r "$SCRIPT_DIR/icons" "$BUILD_DIR/"
cp -r "$SCRIPT_DIR/blocked" "$BUILD_DIR/"

# Copiar artefactos compilados (incluye subdirectorios como dist/lib)
cp -r "$SCRIPT_DIR/dist" "$BUILD_DIR/"

# Crear el archivo XPI (es un ZIP con extensión .xpi)
XPI_FILE="$SCRIPT_DIR/${XPI_NAME}-${VERSION}.xpi"
echo "  → Creando archivo XPI..."

cd "$BUILD_DIR"
if command -v zip >/dev/null 2>&1; then
    if ! zip -r -q "$XPI_FILE" ./*; then
        if command -v python3 >/dev/null 2>&1; then
            python3 - "$BUILD_DIR" "$XPI_FILE" <<'PY'
import os
import sys
import zipfile

build_dir, output_path = sys.argv[1:3]
with zipfile.ZipFile(output_path, 'w', compression=zipfile.ZIP_DEFLATED) as archive:
    for root, _, files in os.walk(build_dir):
        for filename in files:
            full_path = os.path.join(root, filename)
            relative_path = os.path.relpath(full_path, build_dir)
            archive.write(full_path, relative_path)
PY
        else
            echo -e "${RED}Error: 'zip' falló y no se encontró 'python3' para crear el archivo XPI${NC}"
            exit 1
        fi
    fi
elif command -v python3 >/dev/null 2>&1; then
    python3 - "$BUILD_DIR" "$XPI_FILE" <<'PY'
import os
import sys
import zipfile

build_dir, output_path = sys.argv[1:3]
with zipfile.ZipFile(output_path, 'w', compression=zipfile.ZIP_DEFLATED) as archive:
    for root, _, files in os.walk(build_dir):
        for filename in files:
            full_path = os.path.join(root, filename)
            relative_path = os.path.relpath(full_path, build_dir)
            archive.write(full_path, relative_path)
PY
else
    echo -e "${RED}Error: No se encontró 'zip' ni 'python3' para crear el archivo XPI${NC}"
    exit 1
fi

cd "$SCRIPT_DIR"

# Limpiar
rm -rf "$BUILD_DIR"

# Verificar
if [ -f "$XPI_FILE" ]; then
    SIZE=$(du -h "$XPI_FILE" | cut -f1)
    echo ""
    echo -e "${GREEN}✓ Extensión empaquetada correctamente${NC}"
    echo ""
    echo "  Archivo: $XPI_FILE"
    echo "  Tamaño:  $SIZE"
    echo ""
    echo "Para instalar:"
    echo "  1. Abre Firefox → about:addons"
    echo "  2. Clic en el engranaje → 'Instalar complemento desde archivo...'"
    echo "  3. Selecciona el archivo XPI"
    echo ""
    echo "Nota: La extensión no está firmada, por lo que solo funcionará"
    echo "      en Firefox Developer Edition/Nightly con xpinstall.signatures.required = false"
    echo ""
else
    echo -e "${RED}Error: No se pudo crear el archivo XPI${NC}"
    exit 1
fi
