Run from `edge-extension`:

```sh
python3 tests/run_lua_tests.py ../init.lua
node --input-type=module -e 'import("./tests/test_background.mjs").then(async m => console.log(await m.runTests(process.cwd())))'
```

The Python runner uses the Lua runtime bundled with Hammerspoon on macOS. With a standalone Lua 5.4 interpreter, use `lua tests/test_switcher.lua ../init.lua` instead.

The Lua checks execute the restored config against Hammerspoon mocks and cover the original Option+Tab / Option+Shift+Tab hotkeys, Option-release selection, keyboard cancellation, grid navigation, window resizing, 96 layouts, asynchronous icons, and app activation. They also check that a missing focused-window result does not dismiss an open switcher while Option remains held, and that Control+Tab stays native. The JavaScript checks execute the extension worker against browser mocks and cover cached icons, concurrent requests, navigation/close races, scope, background metadata updates, and failed or invalid image responses.
