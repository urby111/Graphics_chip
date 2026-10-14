#!/usr/bin/env bash
# Ubuntu 24.04 WSL. Unpack compiler packages locally; no sudo/system install.
set -euo pipefail
kv_root="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$kv_root/toolchain/packages"
if [[ -f "$kv_root/toolchain/root/usr/libexec/gcc-cross/aarch64-linux-gnu/13/cc1" ]]; then
 exit 0
fi
cd "$kv_root/toolchain/packages"
apt-get download gcc-13-aarch64-linux-gnu=13.2.0-23ubuntu4cross1 \
 cpp-13-aarch64-linux-gnu=13.2.0-23ubuntu4cross1 \
 binutils-aarch64-linux-gnu=2.42-4ubuntu2 \
 libgcc-13-dev-arm64-cross=13.2.0-23ubuntu4cross1
for compiler_package in ./*.deb; do dpkg-deb -x "$compiler_package" ../root; done
