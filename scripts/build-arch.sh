#!/bin/bash
set -euo pipefail

VERSION="${1:-dev}"
ARTIFACTS_DIR="${2:-artifacts}"
OUTPUT_DIR="${3:-.}"

# Arch versions can't have hyphens, replace with underscores
ARCH_VERSION="${VERSION//-/_}"

mkdir -p "${OUTPUT_DIR}/archpkg/pkg/usr/bin"
cp "${ARTIFACTS_DIR}/poof-linux-x86_64-glibc/poof-linux-x86_64-glibc" "${OUTPUT_DIR}/archpkg/pkg/usr/bin/poof"
chmod 755 "${OUTPUT_DIR}/archpkg/pkg/usr/bin/poof"

cd "${OUTPUT_DIR}/archpkg/pkg"
cat > .PKGINFO << EOF
pkgname = poof
pkgver = ${ARCH_VERSION}-1
pkgdesc = Ephemeral filesystem isolation tool
url = https://github.com/jarred-sumner/poof
arch = x86_64
license = MIT
EOF

tar -cJf "../poof-${ARCH_VERSION}-1-x86_64.pkg.tar.xz" .PKGINFO usr
echo "Built: poof-${ARCH_VERSION}-1-x86_64.pkg.tar.xz"
