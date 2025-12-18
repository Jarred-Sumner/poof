#!/bin/bash
set -euo pipefail

VERSION="${1:-dev}"
ARTIFACTS_DIR="${2:-artifacts}"
OUTPUT_DIR="${3:-.}"

for arch in amd64:x86_64 arm64:aarch64; do
    DEB_ARCH="${arch%%:*}"
    ZIG_ARCH="${arch##*:}"

    PKG_DIR="${OUTPUT_DIR}/poof_${VERSION}_${DEB_ARCH}"
    mkdir -p "${PKG_DIR}/DEBIAN"
    mkdir -p "${PKG_DIR}/usr/bin"

    cp "${ARTIFACTS_DIR}/poof-linux-${ZIG_ARCH}-glibc/poof-linux-${ZIG_ARCH}-glibc" "${PKG_DIR}/usr/bin/poof"
    chmod 755 "${PKG_DIR}/usr/bin/poof"

    cat > "${PKG_DIR}/DEBIAN/control" << EOF
Package: poof
Version: ${VERSION}
Section: utils
Priority: optional
Architecture: ${DEB_ARCH}
Maintainer: Jarred Sumner <jarred@jarredsumner.com>
Description: Ephemeral filesystem isolation tool
 Run any command in an isolated environment where filesystem
 changes never affect your host. Uses Linux namespaces and overlayfs.
Homepage: https://github.com/jarred-sumner/poof
EOF

    dpkg-deb --build "${PKG_DIR}"
    echo "Built: ${PKG_DIR}.deb"
done
