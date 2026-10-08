# Edge MRU Tab Switcher

An experimental Option+Tab switcher for Microsoft Edge on macOS, built with Hammerspoon and a small Edge extension.

Hold **Option (⌥)** and press **Tab** to browse recently used tabs. Release Option to activate the selected tab. The black overlay shows cached page previews, site icons, and numbered cards, and scales with the Edge window.

## Features

- Option+Tab and Option+Shift+Tab to cycle forwards and backwards.
- Arrow keys and number keys 1–9 to select a card while Option is held.
- Escape to cancel without changing tabs.
- Separate recent-tab histories for each Edge window, with an optional all-windows mode.
- 2–25 displayed tabs, configured from the extension popup.
- Black background at 90% opacity, cached previews, and site icons.
- A panel that follows the Edge window's position and size across monitors.
- Persistent recent-tab history and sleep/wake recovery.

## How it works

`init.lua` runs in Hammerspoon. It handles the keyboard shortcut, draws the overlay, and activates the selected tab.

`edge-extension/background.js` runs in Edge. It tracks tab history, captures previews, loads site icons, and communicates with Hammerspoon over a local bridge at `127.0.0.1:27123`. The extension's HTML, CSS, and `options.js` implement its settings popup.

## Install

You need macOS, [Microsoft Edge](https://www.microsoft.com/edge), [Hammerspoon](https://www.hammerspoon.org/), and Python 3 for the preparation step.

1. Download this repository using **Code → Download ZIP**, or clone it, and open a terminal in the project folder.
2. Generate the installation files:

   ```sh
   python3 scripts/prepare_install.py
   ```

   This creates `dist/init.lua` and `dist/edge-extension/` with a randomly generated local bridge token. The generated files are excluded from Git. Run the script again after source changes; it retains the existing token.

3. Install Hammerspoon in `/Applications`, launch it, and grant the requested Accessibility access in macOS System Settings.
4. Install the generated Lua file. If you already have a Hammerspoon configuration, merge this script into it or load it from a separate file. To replace an existing configuration, first save a backup:

   ```sh
   mkdir -p ~/.hammerspoon
   if [ -f ~/.hammerspoon/init.lua ]; then
     cp ~/.hammerspoon/init.lua ~/.hammerspoon/init.lua.backup-$(date +%Y%m%d-%H%M%S)
   fi
   cp dist/init.lua ~/.hammerspoon/init.lua
   ```

5. Choose **Reload Config** from Hammerspoon's menu. If macOS asks for permission to control Microsoft Edge when the AppleScript fallback runs, allow it.
6. Open `edge://extensions`, enable **Developer mode**, choose **Load unpacked**, and select **`dist/edge-extension`**. See [Microsoft's sideloading instructions](https://learn.microsoft.com/en-us/microsoft-edge/extensions/getting-started/extension-sideloading).
7. Open the extension popup and select the number of tabs and the tab scope. Visit a few tabs, then try Option+Tab.

Keep the generated extension folder in place after installing it. Edge loads an unpacked extension directly from that folder. Optionally enable **Allow access to file URLs** if you want previews for local files.

## Update

Pull or download the new source, run `python3 scripts/prepare_install.py`, install the updated `dist/init.lua`, reload Hammerspoon, and reload the extension at `edge://extensions`.

## Current status and limitations

The first published baseline uses the shortcut implementation restored before the stricter focused-window checks were added. It enables the original Hammerspoon hotkeys using Edge app activation notifications. It does not include the later per-key focused-window checks or the subsequent release/focus-gap changes.

Intermittent shortcut failures have been reported and are still being investigated. This project is experimental; the mock tests check behavior but do not guarantee keyboard reliability on every macOS setup. Some browser pages cannot provide previews, so their cards show a placeholder.

The bridge is local to this Mac. The extension stores recent-tab metadata locally and syncs its display-count and scope settings through Edge's extension storage. Page previews and icons are cached in memory. It has no analytics or project-operated cloud service. The bridge is intended for a trusted local setup; its shared token is not a complete security boundary, and it must not be exposed to the network.

## Development and checks

From `edge-extension`:

```sh
python3 tests/run_lua_tests.py ../init.lua
node --input-type=module -e 'import("./tests/test_background.mjs").then(async m => console.log(await m.runTests(process.cwd())))'
```

The Python runner uses Hammerspoon's bundled Lua runtime on macOS. With a standalone Lua 5.4 interpreter, use `lua tests/test_switcher.lua ../init.lua`. See [the test notes](edge-extension/tests/README.md) for coverage.

Commit source changes before installing a new version, and use tags to mark versions you want to return to. Generated installation files in `dist/` should stay out of commits.

## License

[MIT](LICENSE).
