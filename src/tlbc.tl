-- tlbc: Typed Lua Bundle Compiler (single-file self-hosting milestone)
-- Build driver written in Teal. POSIX shell and a native C compiler are build-time tools.

local record Options
   source: string
   output: string
   workdir: string
   lua_pkg: string
   compiler: string
   luac: string
   tl: string
   target: string
   includes: {string}
   fixed_buffer: boolean
   static_link: boolean
end

local function quote(s: string): string
   -- POSIX shell escaping; no unquoted user-supplied strings enter commands.
   return "'" .. s:gsub("'", "'\\''") .. "'"
end

local function execute(command: string)
   io.stderr:write("+ ", command, "\n")
   local ok = os.execute(command)
   if not ok then
      error("command failed: " .. command, 0)
   end
end

local function read_all(path: string): string
   local f, err = io.open(path, "rb")
   if not f then
      error("unable to open " .. path .. ": " .. tostring(err), 0)
   end
   local data = f:read("*a")
   f:close()
   if not data then
      error("unable to read " .. path, 0)
   end
   return data
end

local function write_all(path: string, data: string)
   local f, err = io.open(path, "wb")
   if not f then
      error("unable to create " .. path .. ": " .. tostring(err), 0)
   end
   f:write(data)
   f:close()
end

local record ModuleChunk
   name: string
   source: string
   bytecode: string    -- "" for C modules
   symbol: string      -- "luaopen_x" for C modules, "" otherwise
   libpath: string     -- library file to link for C modules, "" otherwise
   rpath: string       -- -Wl,-rpath dir needed when libpath is a .so
end

local function c_array(lines: {string}, name: string, data: string)
   table.insert(lines, "static const unsigned char " .. name .. "[] = {\n")
   for i = 1, #data do
      if (i - 1) % 12 == 0 then table.insert(lines, "  ") end
      table.insert(lines, string.format("0x%02x,", string.byte(data, i)))
      table.insert(lines, i % 12 == 0 and "\n" or " ")
   end
   table.insert(lines, "\n};\n")
end

local function emit_header(path: string, main_bytecode: string, modules: {ModuleChunk})
   local lines: {string} = {"#ifndef TLBC_EMBEDDED_H\n#define TLBC_EMBEDDED_H\n"}
   c_array(lines, "tlbc_main", main_bytecode)
   for _, mod in ipairs(modules) do
      if mod.symbol ~= "" then
         table.insert(lines, "extern int " .. mod.symbol .. "(lua_State *L);\n")
      end
   end
   table.insert(lines, [[
typedef struct {
  const char *name;
  const unsigned char *data;
  size_t length;
  lua_CFunction open;
} tlbc_module;
]])
   for i, mod in ipairs(modules) do
      if mod.symbol == "" then
         c_array(lines, "tlbc_module_" .. tostring(i), mod.bytecode)
      end
   end
   table.insert(lines, "static const tlbc_module tlbc_modules[] = {\n")
   for i, mod in ipairs(modules) do
      if mod.symbol == "" then
         table.insert(lines, "  {" .. string.format("%q", mod.name) .. ", tlbc_module_" ..
            tostring(i) .. ", sizeof(tlbc_module_" .. tostring(i) .. "), NULL},\n")
      else
         table.insert(lines, "  {" .. string.format("%q", mod.name) ..
            ", NULL, 0, " .. mod.symbol .. "},\n")
      end
   end
   table.insert(lines, "  {NULL, NULL, 0}\n};\n#endif\n")
   write_all(path, table.concat(lines))
end

local function file_exists(path: string): boolean
   local f = io.open(path, "rb")
   if f then
      f:close()
      return true
   end
   return false
end

local function capture(command: string): string
   local p = io.popen(command, "r")
   if not p then
      return ""
   end
   local out = p:read("*a") or ""
   p:close()
   return (out:gsub("%s+$", ""))
end

-- Locate a tool like bootstrap.sh does: PATH first, then luarocks' bin dirs.
local function find_tool(name: string): string
   if os.execute("command -v " .. quote(name) .. " >/dev/null 2>&1") then
      return name
   end
   if not name:find("/") then
      local dirs: {string} = {}
      if os.execute("command -v luarocks >/dev/null 2>&1") then
         table.insert(dirs, capture("luarocks config deploy_bin_dir 2>/dev/null"))
      end
      table.insert(dirs, (os.getenv("HOME") or "") .. "/.luarocks/bin")
      for _, dir in ipairs(dirs) do
         local path = dir .. "/" .. name
         if dir ~= "" and os.execute("test -x " .. quote(path)) then
            return path
         end
      end
   end
   error("'" .. name .. "' not found in PATH or luarocks bin dirs; " ..
         "install it with: luarocks install " .. name, 0)
end

-- Install prefix of the running interpreter, recovered from package.cpath.
-- Covers source-built installs (asdf, `make install`) that ship no .pc file.
local function lua_prefix(): string | nil
   for entry in package.cpath:gmatch("[^;]+") do
      local prefix = entry:match("^(.*)/lib/lua/[^/]+/%?%.so$")
      if prefix and file_exists(prefix .. "/include/lua.h") then
         return prefix
      end
   end
   return nil
end

local function manual_flags(incdir: string, libdir: string): string
   local lib: string
   if file_exists(libdir .. "/liblua.a") then
      lib = quote(libdir .. "/liblua.a")
   else
      lib = "-L" .. quote(libdir) .. " -llua"
   end
   return "-I" .. quote(incdir) .. " " .. lib .. " -Wl,-E -ldl"
end

-- Compile/link flags for embedding the running interpreter's liblua.
local function lua_flags(opt: Options): string
   local incdir: string | nil
   local libdir: string | nil
   local prefix = lua_prefix()
   if prefix then
      incdir = prefix .. "/include"
      libdir = prefix .. "/lib"
   elseif os.execute("command -v luarocks >/dev/null 2>&1") then
      -- Compiled binary: package.cpath is compiled-in, so ask luarocks
      -- where the Lua dev files for its configured interpreter live.
      local id = capture("luarocks config variables.LUA_INCDIR 2>/dev/null")
      if id ~= "" and file_exists(id .. "/lua.h") then
         incdir = id
         local ld = capture("luarocks config variables.LUA_LIBDIR 2>/dev/null")
         libdir = ld ~= "" and ld or (id:gsub("/include$", "/lib"))
      end
   end
   local pc = "pkg-config"
   if libdir then
      -- Let pkg-config also see .pc files under the detected install prefix.
      pc = "PKG_CONFIG_PATH=" .. quote(libdir .. "/pkgconfig") ..
           ":\"$PKG_CONFIG_PATH\" pkg-config"
   end
   if os.execute(pc .. " --exists " .. quote(opt.lua_pkg) .. " >/dev/null 2>&1") then
      return capture(pc .. " --cflags --libs " .. quote(opt.lua_pkg))
   end
   if incdir and libdir then
      return manual_flags(incdir, libdir)
   end
   error("cannot determine Lua flags: pkg-config package '" .. opt.lua_pkg ..
         "' not found and no Lua dev files could be located", 0)
end

local function dirname(path: string): string
   return path:match("^(.*)/[^/]+$") or "."
end

-- Lexer for dependency discovery. Skip whitespace, line/long comments and
-- recognize quoted and long-bracket strings without interpreting their bodies.
-- This is intentionally not a full Lua parser: only direct literal global
-- require calls are statically discoverable.
local record Token
   kind: string
   value: string
end

local function long_open(src: string, pos: integer): integer | nil
   if src:sub(pos, pos) ~= "[" then return nil end
   local j = pos + 1
   while src:sub(j, j) == "=" do j = j + 1 end
   if src:sub(j, j) == "[" then return j - pos - 1 end
   return nil
end

local function long_end(src: string, pos: integer, eq: integer): integer
   local close = "]" .. string.rep("=", eq) .. "]"
   local start = pos + eq + 2
   local found = src:find(close, start, true)
   return found and (found + #close) or (#src + 1)
end

local function lex(src: string): {Token}
   local tokens: {Token} = {}
   local i = 1
   local n = #src
   while i <= n do
      local ch = src:sub(i, i)
      if ch:match("%s") then
         i = i + 1
      elseif src:sub(i, i + 1) == "--" then
         local eq = long_open(src, i + 2)
         if eq ~= nil then
            i = long_end(src, i + 2, eq as integer)
         else
            local j = src:find("\n", i + 2, true)
            i = j and (j + 1) or (n + 1)
         end
      elseif ch == "\"" or ch == "'" then
         local quote_char = ch
         local parts: {string} = {}
         i = i + 1
         while i <= n do
            local c = src:sub(i, i)
            if c == "\\" then
               local next_char = src:sub(i + 1, i + 1)
               if next_char == "\n" then
                  i = i + 2
               elseif next_char == "z" then
                  i = i + 2
                  while i <= n and src:sub(i, i):match("%s") do i = i + 1 end
               else
                  local escapes: {string:string} = {n="\n", r="\r", t="\t", a="\a", b="\b", f="\f", v="\v"}
                  table.insert(parts, escapes[next_char] or next_char)
                  i = i + 2
               end
            elseif c == quote_char then
               i = i + 1
               break
            else
               table.insert(parts, c)
               i = i + 1
            end
         end
         table.insert(tokens, {kind="string", value=table.concat(parts)})
      elseif ch == "[" and long_open(src, i) ~= nil then
         local eq = long_open(src, i) as integer
         local start = i + eq + 2
         local endpos = long_end(src, i, eq)
         local value = src:sub(start, endpos - eq - 3)
         if value:sub(1, 1) == "\n" then value = value:sub(2) end
         table.insert(tokens, {kind="string", value=value})
         i = endpos
      elseif ch:match("[%a_]") then
         local j = i + 1
         while j <= n and src:sub(j, j):match("[%w_]") do j = j + 1 end
         table.insert(tokens, {kind="ident", value=src:sub(i, j-1)})
         i = j
      else
         table.insert(tokens, {kind="punct", value=ch})
         i = i + 1
      end
   end
   return tokens
end

local function find_requires(src: string): {string}
   local tokens = lex(src)
   local mods: {string} = {}
   local seen: {string:boolean} = {}
   for i, t in ipairs(tokens) do
      if t.kind == "ident" and t.value == "require" and
         (i == 1 or (tokens[i-1].value ~= "." and tokens[i-1].value ~= ":")) then
         local next_token = tokens[i+1]
         local literal: Token | nil = nil
         if next_token then
            if next_token.kind == "string" then
               literal = next_token
            elseif next_token.value == "(" then
               local param = tokens[i+2]
               local close = tokens[i+3]
               if param and param.kind == "string" and close and close.value == ")" then
                  literal = param
               end
            end
         end
         if literal then
            local name = (literal as Token).value
            if name ~= "" and not seen[name] then
               seen[name] = true
               table.insert(mods, name)
            end
         end
      end
   end
   return mods
end

local function search_dirs(opt: Options): {string}
   local dirs: {string} = {dirname(opt.source), "."}
   for _, d in ipairs(opt.includes) do
      table.insert(dirs, d)
   end
   return dirs
end

local function dir_exists(path: string): boolean
   return os.execute("test -d " .. quote(path)) == true
end

local function lua_version(): string
   for entry in package.cpath:gmatch("[^;]+") do
      local v = entry:match("/lib/lua/([%d%.]+)/")
      if v then
         return v
      end
   end
   return _VERSION:match("[%d%.]+") or "5.5"
end

-- Resolve a module name like Lua's loader: <name as path>, then
-- <name>/init. Each dir is tried as a plain source dir and as a
-- luarocks-style tree root (<dir>/share/lua/<ver>/, <dir>/lib/lua/<ver>/).
local function find_module(name: string, dirs: {string}): string | nil
   local rel = (name:gsub("%.", "/"))
   local ver = lua_version()
   for _, dir in ipairs(dirs) do
      for _, base in ipairs({dir, dir .. "/share/lua/" .. ver, dir .. "/lib/lua/" .. ver}) do
         for _, ext in ipairs({".tl", ".lua", "/init.tl", "/init.lua"}) do
            local path = base .. "/" .. rel .. ext
            if file_exists(path) then
               return path
            end
         end
      end
   end
   return nil
end

-- C modules export luaopen_<name>; Lua's rule: text up to the first dash is
-- dropped from the module name, then dots become underscores.
local function luaopen_name(name: string): string
   local base = name:match("^[^%-]*%-(.*)$") or name
   return "luaopen_" .. (base:gsub("%.", "_"))
end

-- Host directories holding C modules, in two phases per bundling policy:
-- system-style dirs first, luarocks trees after.
local function c_module_dirs(opt: Options): {string}, {string}
   local sys: {string} = {}
   local seen: {string:boolean} = {}
   local function add(d: string)
      if d ~= "" and not seen[d] then
         seen[d] = true
         table.insert(sys, d)
      end
   end
   for _, d in ipairs(opt.includes) do
      add(d)
   end
   for entry in package.cpath:gmatch("[^;]+") do
      add((entry:gsub("/%?%.so$", "")))
   end
   local ver = lua_version()
   local prefix = lua_prefix()
   if prefix then
      add(prefix .. "/lib/lua/" .. ver)
   end
   add("/usr/local/lib/lua/" .. ver)
   add("/usr/lib64/lua/" .. ver)
   add("/usr/lib/lua/" .. ver)
   add(".")

   local lr: {string} = {}
   if os.execute("command -v luarocks >/dev/null 2>&1") then
      local dir = capture("luarocks config deploy_lib_dir 2>/dev/null")
      if dir ~= "" then
         table.insert(lr, dir)
      end
   end
   table.insert(lr, (os.getenv("HOME") or "") .. "/.luarocks/lib/lua/" .. ver)
   return sys, lr
end

-- Search a C library exporting the module's luaopen symbol. Mirrors Lua's
-- searchers: <name as path>.<ext> first, then the root component (all-in-one
-- style: a.so may provide luaopen_a_b). Static archives are preferred over
-- shared objects within each phase.
local function abs_dir(path: string): string
   local d = dirname(path)
   local out = capture("cd " .. quote(d) .. " 2>/dev/null && pwd")
   if out ~= "" then
      return out
   end
   return d
end

-- Search a C library exporting the module's luaopen symbol. Mirrors Lua's
-- searchers: <name as path>.<ext> first, then the root component (all-in-one
-- style: a.so may provide luaopen_a_b). Each dir is tried as a plain module
-- dir and as a luarocks-style tree root (<dir>/lib/lua/<ver>/). Static
-- archives are preferred over shared objects within each phase.
local function find_c_module(name: string, sys: {string}, lr: {string}): string | nil
   local rel = (name:gsub("%.", "/"))
   local root = name:match("^[^%.]+") or rel
   local ver = lua_version()
   for _, dirs in ipairs({sys, lr}) do
      for _, dir in ipairs(dirs) do
         for _, ext in ipairs({".a", ".so"}) do
            for _, stem in ipairs({rel, root}) do
               for _, base in ipairs({dir, dir .. "/lib/lua/" .. ver}) do
                  local path = base .. "/" .. stem .. ext
                  if file_exists(path) then
                     return path
                  end
               end
            end
         end
      end
   end
   return nil
end

-- Standard library names resolve via package.loaded after luaL_openlibs;
-- requiring them is a no-op, so they are neither bundled nor warned about.
local stdlib: {string:boolean} = {
   package = true, coroutine = true, debug = true, io = true,
   math = true, os = true, string = true, table = true, utf8 = true,
}

-- Discover transitive dependencies. Each module stays independent and is
-- compiled into its own bytecode chunk after this walk. Returns the module
-- list plus extra linker arguments for bundled C libraries.
local function discover_modules(opt: Options, tl: string, tl_inc: string,
                                main_src: string): {ModuleChunk}, string
   local dirs = search_dirs(opt)
   local sys_dirs, lr_dirs = c_module_dirs(opt)
   local modules: {ModuleChunk} = {}
   local link_args = ""
   local queued: {string:boolean} = {}
   local queue: {string} = {}
   for _, name in ipairs(find_requires(main_src)) do
      queued[name] = true
      table.insert(queue, name)
   end
   local i = 1
   while i <= #queue do
      local name = queue[i]
      i = i + 1
      local path = find_module(name, dirs)
      if path then
         local p = path as string
         local src: string
         local lua_path: string
         if p:sub(-3) == ".tl" then
            lua_path = opt.workdir .. "/module_" .. tostring(i) .. ".lua"
            execute(quote(tl) .. " gen --check --gen-target " .. quote(opt.target) ..
                    " --gen-compat off" .. tl_inc ..
                    " -o " .. quote(lua_path) .. " " .. quote(p))
            src = read_all(lua_path)
         else
            lua_path = p
            src = read_all(p)
         end
         local bytecode_path = opt.workdir .. "/module_" .. tostring(i) .. ".luac"
         execute(quote(opt.luac) .. " -o " .. quote(bytecode_path) .. " " .. quote(lua_path))
         table.insert(modules, {name=name, source=p, bytecode=read_all(bytecode_path),
                                symbol="", libpath="", rpath=""})
         for _, dep in ipairs(find_requires(src)) do
            if not queued[dep] then
               queued[dep] = true
               table.insert(queue, dep)
            end
         end
      elseif not stdlib[name] then
         local clib = find_c_module(name, sys_dirs, lr_dirs)
         if clib then
            local lib = clib as string
            if opt.static_link and lib:sub(-3) == ".so" then
               error("cannot bundle shared library " .. lib ..
                     " into a static executable; provide a .a build instead", 0)
            end
            table.insert(modules, {name=name, source="", bytecode="",
                                   symbol=luaopen_name(name), libpath=lib,
                                   rpath=abs_dir(lib)})
            link_args = link_args .. " " .. quote(lib)
            if lib:sub(-3) == ".so" then
               link_args = link_args .. " -Wl,-rpath," .. quote(abs_dir(lib))
            end
            io.stderr:write("tlbc: bundling C module '" .. name .. "' from " .. lib .. "\n")
         else
            io.stderr:write("tlbc: warning: cannot resolve module '" .. name ..
                            "'; it must be available at runtime\n")
         end
      end
   end
   return modules, link_args
end

local function emit_launcher(path: string, fixed_buffer: boolean)
   local mode = fixed_buffer and "B" or "b"
   local c = [[
#include <stdio.h>
#include <lua.h>
#include <lauxlib.h>
#include <lualib.h>
#include "embedded.h"

/* Called lazily by Lua require(). This receives normal loader arguments
 * (module name, loader data), and invokes the independent bytecode chunk. */
static int tlbc_module_loader(lua_State *L) {
    const tlbc_module *m = (const tlbc_module *)lua_touserdata(L, lua_upvalueindex(1));
    int nargs = lua_gettop(L);
    int rc = luaL_loadbufferx(L, (const char *)m->data, m->length,
                              m->name, "MODE");
    if (rc != LUA_OK) return lua_error(L);
    lua_insert(L, 1);
    lua_call(L, nargs, LUA_MULTRET);
    return lua_gettop(L);
}

static void tlbc_register_modules(lua_State *L) {
    lua_getglobal(L, "package");
    lua_getfield(L, -1, "preload");
    for (const tlbc_module *m = tlbc_modules; m->name != NULL; ++m) {
        if (m->open) {
            /* C modules: the luaopen_* function itself is the loader. */
            lua_pushcfunction(L, m->open);
        } else {
            lua_pushlightuserdata(L, (void *)m);
            lua_pushcclosure(L, tlbc_module_loader, 1);
        }
        lua_setfield(L, -2, m->name);
    }
    lua_pop(L, 2);
}

int main(int argc, char **argv) {
    lua_State *L = luaL_newstate();
    if (!L) { fputs("tlbc: cannot initialize Lua\n", stderr); return 1; }
    luaL_openlibs(L);
    tlbc_register_modules(L);
    lua_createtable(L, argc, 0);
    for (int i = 0; i < argc; ++i) {
        lua_pushstring(L, argv[i]);
        lua_rawseti(L, -2, i);
    }
    lua_setglobal(L, "arg");
    int status = luaL_loadbufferx(L, (const char *)tlbc_main,
                                  sizeof(tlbc_main), "@main", "MODE");
    if (status == LUA_OK) status = lua_pcall(L, 0, 0, 0);
    if (status != LUA_OK) {
        const char *message = lua_tostring(L, -1);
        fprintf(stderr, "%s\n", message ? message : "unknown Lua error");
        lua_close(L);
        return 1;
    }
    lua_close(L);
    return 0;
}
]]
   c = c:gsub('"MODE"', '"' .. mode .. '"')
   write_all(path, c)
end

local function usage()
   print([[
tlbc - Typed Lua Bundle Compiler (prototype)

Usage:
  lua build/tlbc.lua SOURCE.tl -o OUTPUT [options]

Options:
  -o PATH          Executable output path (default: a.out)
  --workdir PATH   Intermediate build directory (default: .tlbc-build)
  --lua-pkg NAME   pkg-config name for Lua (default: lua5.5); falls back to
                   the running interpreter's install prefix when not found
  --cc COMMAND     C compiler (default: cc)
  --luac COMMAND   Lua bytecode compiler (default: luac)
  --tl COMMAND     Teal command (default: tl)
  --target VERSION Teal Lua target (default: 5.5; runs on Lua 5.5)
  -I DIR           Add DIR to the module search path for bundled requires
                   (repeatable; the source's directory and . are always searched)
  --static         Produce a fully static executable (needs a static libc,
                   e.g. glibc-static or musl-gcc via --cc; .so modules cannot
                   be bundled and runtime dlopen will not work)
  --fixed          Lua 5.5 fixed ROM buffer loading mode (default: off)
  -h, --help       Print help

Literal global require calls with a constant module name are discovered by a
Lua lexer (comments/strings ignored). Modules compile to separate bytecode
chunks and load lazily from package.preload. Modules with no .tl/.lua source
are searched as C libraries (.a preferred over .so) in -I dirs, the
interpreter's lib dir, system lua dirs, then luarocks trees, and linked into
the binary. Dynamic requires and unresolvable modules must exist at runtime.
]])
end

local function parse(argv: {string}): Options
   local opt: Options = {
      source = "", output = "a.out", workdir = ".tlbc-build",
      lua_pkg = "lua5.5", compiler = "cc", luac = "luac",
      tl = "tl", target = "5.5", includes = {}, fixed_buffer = false,
      static_link = false
   }
   local i = 1
   while i <= #argv do
      local a = argv[i]
      if a == "--help" or a == "-h" then
         usage()
         os.exit(0)
      elseif a == "--fixed" then
         opt.fixed_buffer = true
      elseif a == "--static" then
         opt.static_link = true
      elseif a == "-o" or a == "--workdir" or a == "--lua-pkg" or a == "--cc" or a == "--luac" or a == "--tl" or a == "--target" or a == "-I" or a == "--include" then
         i = i + 1
         local v = argv[i]
         if not v then
            error("missing argument for " .. a, 0)
         end
         if a == "-o" then opt.output = v
         elseif a == "--workdir" then opt.workdir = v
         elseif a == "--lua-pkg" then opt.lua_pkg = v
         elseif a == "--cc" then opt.compiler = v
         elseif a == "--luac" then opt.luac = v
         elseif a == "--tl" then opt.tl = v
         elseif a == "--target" then opt.target = v
         elseif a == "-I" or a == "--include" then table.insert(opt.includes, v)
         end
      elseif a:sub(1, 1) == "-" then
         error("unknown option: " .. a, 0)
      elseif opt.source == "" then
         opt.source = a
      else
         error("unexpected argument: " .. a, 0)
      end
      i = i + 1
   end
   if opt.source == "" then
      usage()
      error("missing SOURCE.tl", 0)
   end
   return opt
end

local function build(opt: Options)
   -- The generated source and bytecode deliberately use fixed intermediate paths.
   -- Build distinct projects using distinct --workdir values.
   execute("mkdir -p " .. quote(opt.workdir))
   local lua_file = opt.workdir .. "/program.lua"
   local bytecode = opt.workdir .. "/program.luac"
   local header = opt.workdir .. "/embedded.h"
   local launcher = opt.workdir .. "/launcher.c"

   local tl = find_tool(opt.tl)
   -- Tree roots passed via -I may hold .tl/.d.tl under share/lua/<ver>;
   -- expose those to tl's own module search for typechecking.
   local tl_inc = ""
   local ver = lua_version()
   for _, d in ipairs(search_dirs(opt)) do
      tl_inc = tl_inc .. " -I " .. quote(d)
      local share = d .. "/share/lua/" .. ver
      if dir_exists(share) then
         tl_inc = tl_inc .. " -I " .. quote(share)
      end
   end
   execute(quote(tl) .. " gen --check --gen-target " .. quote(opt.target) ..
           " --gen-compat off" .. tl_inc ..
           " -o " .. quote(lua_file) .. " " .. quote(opt.source))
   local modules, c_link_args = discover_modules(opt, tl, tl_inc, read_all(lua_file))
   execute(quote(opt.luac) .. " -o " .. quote(bytecode) .. " " .. quote(lua_file))
   emit_header(header, read_all(bytecode), modules)
   emit_launcher(launcher, opt.fixed_buffer)

   -- C module libs come before liblua so their lua_* references resolve.
   local flags = lua_flags(opt)
   execute(quote(opt.compiler) .. " -O2 -std=c99" ..
           (opt.static_link and " -static" or "") .. " -o " .. quote(opt.output) ..
           " " .. quote(launcher) .. c_link_args .. " " .. flags .. " -lm")
   print("tlbc: created " .. opt.output)
end

local function main(argv: {string})
   local opt = parse(argv)
   build(opt)
end

main(arg)
