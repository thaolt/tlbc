#include <lua.h>
#include <lauxlib.h>
static int add(lua_State *L) {
    lua_pushnumber(L, luaL_checknumber(L, 1) + luaL_checknumber(L, 2));
    return 1;
}
int luaopen_mymath(lua_State *L) {
    lua_newtable(L);
    lua_pushcfunction(L, add);
    lua_setfield(L, -2, "add");
    return 1;
}
