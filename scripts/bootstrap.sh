#!/bin/sh
set -eu

TL=$(command -v tl 2>/dev/null || true)
if [ -z "$TL" ] && command -v luarocks >/dev/null 2>&1; then
    LR_BIN=$(luarocks config deploy_bin_dir 2>/dev/null || true)
    for d in "$LR_BIN" "$HOME/.luarocks/bin"; do
        if [ -n "$d" ] && [ -x "$d/tl" ]; then
            TL="$d/tl"
            break
        fi
    done
fi
if [ -z "$TL" ]; then
    printf 'error: tl not found in PATH or luarocks bin dirs; install it with: luarocks install tl\n' >&2
    exit 1
fi

mkdir -p build
"$TL" gen --check --gen-target 5.3 --gen-compat off -o build/tlbc.lua src/tlbc.tl
printf 'Bootstrap complete: lua build/tlbc.lua --help\n'
