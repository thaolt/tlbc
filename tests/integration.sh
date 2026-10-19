#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
./scripts/bootstrap.sh
# Build a trivial C module as a static archive to exercise C module bundling.
LUA_INC=$(luarocks config variables.LUA_INCDIR 2>/dev/null || pkg-config --variable=includedir lua5.5 2>/dev/null || echo /usr/include/lua5.5)
mkdir -p .tlbc-test-build/mods
cc -O2 -fPIC -I"$LUA_INC" -c tests/mymath.c -o .tlbc-test-build/mymath.o
ar rcs .tlbc-test-build/mods/mymath.a .tlbc-test-build/mymath.o
# Test scanner and actual lazy module loading; source directory resolves counter.lua.
LUA_CMD=${LUA_CMD:-lua}
"$LUA_CMD" build/tlbc.lua tests/lexer_main.tl -o .tlbc-integration     --workdir .tlbc-test-build -I .tlbc-test-build/mods ${TLBC_TEST_FLAGS:-}
./.tlbc-integration > .tlbc-integration.out
grep -qE 'counter-loaded-once[[:space:]]+counter-loaded-once[[:space:]]+true[[:space:]]+true[[:space:]]+method[[:space:]]+42' .tlbc-integration.out
printf 'integration test passed\n'
