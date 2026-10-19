# tlbc — Typed Lua Bundle Compiler

**Experimental v0.1 proof of concept.** The compiler driver is written entirely in **Teal** (`src/tlbc.tl`). It generates a tiny C launcher at build time; no manually maintained C implementation of `tlbc` exists.

## What the prototype does

`Teal → checked Lua source → per-module luac bytecode + linked C modules → generated C registry → executable + Lua VM`

Literal global `require` calls are discovered with a Lua lexical scanner (which skips comments and string bodies). Each resolved `.tl`/`.lua` module is **compiled separately into bytecode**. Modules with no Lua source are searched as **C libraries** (`.a` preferred, then `.so`) across the include dirs, the interpreter's lib dir, system Lua dirs, and luarocks trees — and linked into the binary, registering their `luaopen_*` in `package.preload`. A generated C registry inserts lightweight lazy loaders, so modules are loaded by the VM only on the first `require`. By default the output dynamically links libc; pass `--static` for a fully static executable (requires a static libc such as `glibc-static`, or `musl-gcc` via `--cc`). In a static binary, `package.loadlib`/runtime `.so` loading will not work — bundled bytecode and `.a` C modules are unaffected.

## Requirements

- POSIX shell environment, `mkdir`, C compiler
- Teal `tl` compiler with `tl gen --check` and `--gen-target`
- A matched `luac`/Lua runtime development library; defaults to Lua 5.5
- A Lua interpreter for running the bootstrap output
- Optional: `pkg-config` and `luarocks` — Lua dev flags are auto-detected from the interpreter's install prefix or `luarocks config` when no `.pc` file exists (e.g. asdf installs)

**Important:** `luac` and the linked Lua VM must be the same Lua version/build family. Ensure `luac -v` matches the version selected by `--lua-pkg`. Teal's `--gen-target 5.3` emits Lua source compatible with later versions, including Lua 5.5; it does not select the version of the bytecode.

## Bootstrap

```sh
./scripts/bootstrap.sh
lua build/tlbc.lua --help
```

If your host interpreter is `lua5.5`, use that instead of `lua`.

## Compile your first Teal program

```sh
lua build/tlbc.lua examples/hello.tl -o hello \
    --lua-pkg lua5.5 --luac luac5.5
./hello
```

If your `luac` command already targets Lua 5.5, omit `--luac`. For a Lua 5.4 toolchain:

```sh
lua build/tlbc.lua examples/hello.tl -o hello \
    --lua-pkg lua5.4 --luac luac5.4
```

Use `--fixed` **only** when linking with Lua 5.5, to opt into fixed ROM buffer mode (`luaL_loadbufferx(..., "B")`).

## Multi-module programs

`examples/bundle/` demonstrates every resolution path:

```sh
lua build/tlbc.lua examples/bundle/main.tl -o bundled
./bundled
```

- `require("greeter")` → `greeter.tl` next to `main.tl`
- `require("util.strings")` → `util/strings.tl` (dots map to directories)
- `require("config")` → `config/init.tl`
- `require("legacy")` → `legacy.lua`, a plain Lua module; `legacy.d.tl` gives `tl gen --check` its type information
- Modules may `require` each other transitively

Search order: the entry file's directory, `.`, then any `-I DIR` flags. Dynamic `require(var)` calls and aliased/shadowed `require` are **not** statically bundled — they must exist at runtime.

## C modules (sqlite3 example)

Modules that don't resolve to `.tl`/`.lua` are searched as C libraries exporting `luaopen_<name>` (dots → underscores; text up to the first `-` dropped). `-I` dirs may point at a plain module dir or a luarocks-style tree root (`<dir>/lib/lua/<ver>/` is probed automatically). `.a` is preferred over `.so`; linked `.so` files get an absolute `rpath`.

```sh
luarocks --tree .rocks install lsqlite3
lua build/tlbc.lua examples/sqlite/main.tl -I .rocks -o sqlite_app
./sqlite_app
```

`examples/sqlite/` runs an in-memory database; the resulting binary needs no luarocks tree or `package.cpath` entry — `lsqlite3.so` is resolved via rpath, and `libsqlite3` comes from the system.

## HTTP fetch example (luasocket)

`examples/http/` fetches a web page with `socket.http` + `ltn12` — a real-world mix of Lua modules (`socket/http.lua`, `socket/url.lua`, `ltn12.lua`, ...) and C modules (`socket/core.so`, `mime/core.so`), all resolved from the same `-I` tree:

```sh
luarocks --tree .rocks install luasocket
lua build/tlbc.lua examples/http/main.tl -I .rocks -o httpapp
./httpapp
```

`require`s of standard library names (`string`, `table`, `math`, ...) are no-ops: they resolve via `package.loaded` at runtime and are neither bundled nor warned about.

## External assets

`examples/assets/` keeps data files **outside** the binary: they are read at run time with plain `io.open`, resolved against the process cwd — run the binary from its install directory — or redirected with `APP_DATA_DIR` for deployed layouts:

```sh
lua build/tlbc.lua examples/assets/main.tl -o examples/assets/app
cd examples/assets && ./app
APP_DATA_DIR=/opt/app/share ./app   # override lookup dir
```

## Independent chunks and lexical discovery

`tlbc` compiles the entry source and every discovered dependency separately with `luac`. The launcher embeds the bytecode in constant byte arrays and registers C closures into `package.preload` without parsing/loading module bytecode at startup. Standard `require()` caching via `package.loaded` remains unchanged. Each module receives the standard Lua loader arguments. Cyclic `require()` behavior follows the linked Lua implementation; circular execution is not automatically resolved.

The lexer recognizes direct literal forms including `require("pkg")`, `require "pkg"`, and `require([[pkg]])`, ignoring string contents, long/line comments and `object.require`/`object:require`. This is **lexical**, not full semantic AST analysis: shadowed global identifiers and programmatically constructed `require` expressions cannot be resolved reliably. It does not follow imports hidden behind dynamic calls or `load`/`dofile`. `require` calls inside unused functions are included for conservative bundling.

## Self-compilation proof

```sh
lua build/tlbc.lua src/tlbc.tl -o tlbc --lua-pkg lua5.5 --luac luac5.5
./tlbc --help
./tlbc examples/hello.tl -o hello2 --lua-pkg lua5.5 --luac luac5.5
./hello2
```

The native `tlbc` executable contains the Teal-written build driver compiled into bytecode and embedded into the generated C launcher. Its use still requires Teal, `luac`, `pkg-config`, and a C compiler **at build time**.

## Current constraints

- Only literal `require` calls are bundled; dynamic requires and unresolvable C modules use ordinary Lua runtime lookup.
- POSIX-only shell orchestration, not Windows native support.
- Intermediate files are written into `--workdir` (`.tlbc-build` by default); do not share workdir between concurrent builds.
- Linkage defaults to system pkg-config flags or auto-detected dev paths and may be **dynamic**; `--static` produces a fully static executable when a static libc is installed.
- Generated binaries include all Lua standard libraries via `luaL_openlibs`.
- `tlbc` compilation has **not been end-to-end tested in this environment**, which lacks the Teal CLI and Lua compiler. Check results with your toolchain and report compiler errors for refinement.

## Regression tests

```sh
./tests/integration.sh
```

Tests require `tl`, a matching `luac`, Lua development files, and a working C compiler. The test invokes the bootstrap and builds a bundle containing a mixture of Teal and Lua modules. It checks that commented-out and string-contained fake imports are not resolved, and that a module is initialized only once on multiple `require`s.

## Proposed v0.2

- Add `tlbc.toml` or Lua-based project manifest (decide format), module roots, resources.
- Flag to strip unused standard libraries.
- Remove POSIX-shell dependency with carefully scoped native helpers only if necessary.
- Add reproducible tests and CI across supported Lua toolchains.

## License

BSD-3-Clause — see [LICENSE](LICENSE).
