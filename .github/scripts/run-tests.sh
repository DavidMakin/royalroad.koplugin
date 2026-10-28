#!/usr/bin/env bash
# Runs the standalone Lua tests with KOReader's bundled LuaJIT.
# Without KOREADER_DIR, downloads the pinned KOReader release and extracts it.
set -euo pipefail

readonly VERSION="v2026.07.1"
readonly ASSET="koreader-linux-x86_64-${VERSION}.tar.xz"
readonly SHA256="299aadb28147a25e9432ced1214ea444a4184393b5ae97cf42402c8a61b1a1b0"

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
plugin_dir="${repo_root}/royalroad.koplugin"

if [[ -z "${KOREADER_DIR:-}" ]]; then
    work="$(mktemp -d)"
    curl -fsSL --retry 3 -o "${work}/${ASSET}" \
        "https://github.com/koreader/koreader/releases/download/${VERSION}/${ASSET}"
    echo "${SHA256}  ${work}/${ASSET}" | sha256sum -c -
    tar -xJf "${work}/${ASSET}" -C "${work}"
    KOREADER_DIR="${work}/lib/koreader"
fi
export KOREADER_DIR

cd "${KOREADER_DIR}"
for t in test_anubis test_http; do
    out="$(./luajit "${plugin_dir}/${t}.lua" 2>&1)" || { echo "${out}"; echo "${t} failed"; exit 1; }
    echo "${out}"
    grep -q "all passed" <<<"${out}" || { echo "${t}: no 'all passed' line"; exit 1; }
done
