"""Run the switcher tests using the Lua runtime bundled with Hammerspoon."""
import ctypes
import sys
from pathlib import Path

runtime = ctypes.CDLL(
    "/Applications/Hammerspoon.app/Contents/Frameworks/LuaSkin.framework/Versions/A/LuaSkin"
)
runtime.luaL_newstate.restype = ctypes.c_void_p
runtime.luaL_openlibs.argtypes = [ctypes.c_void_p]
runtime.luaL_loadfilex.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_char_p]
runtime.lua_pcallk.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_int, ctypes.c_int, ctypes.c_longlong, ctypes.c_void_p]
runtime.lua_tolstring.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_void_p]
runtime.lua_tolstring.restype = ctypes.c_char_p
runtime.lua_close.argtypes = [ctypes.c_void_p]
runtime.luaL_loadstring.argtypes = [ctypes.c_void_p, ctypes.c_char_p]

state = runtime.luaL_newstate()
try:
    runtime.luaL_openlibs(state)
    config = str(Path(sys.argv[1] if len(sys.argv) > 1 else "../init.lua").resolve())
    # Lua long strings preserve file paths without shell interpolation.
    assert "]]" not in config
    result = runtime.luaL_loadstring(state, f"arg = {{ [[{config}]] }}".encode())
    if not result:
        result = runtime.lua_pcallk(state, 0, 0, 0, 0, None)
    if not result:
        result = runtime.luaL_loadfilex(state, str(Path(__file__).with_name("test_switcher.lua")).encode(), None)
    if not result:
        result = runtime.lua_pcallk(state, 0, 0, 0, 0, None)
    if result:
        raise RuntimeError(runtime.lua_tolstring(state, -1, None).decode())
finally:
    runtime.lua_close(state)
