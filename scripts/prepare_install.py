#!/usr/bin/env python3
"""Create local installation files without putting bridge tokens in Git."""

from pathlib import Path
import re
import secrets
import shutil

ROOT = Path(__file__).resolve().parents[1]
OUTPUT = ROOT / "dist"
PLACEHOLDER = "__EDGE_MRU_LOCAL_TOKEN__"


def main():
    lua = (ROOT / "init.lua").read_text()
    worker = (ROOT / "edge-extension" / "background.js").read_text()
    if lua.count(PLACEHOLDER) != 1 or worker.count(PLACEHOLDER) != 1:
        raise SystemExit("Expected one bridge-token placeholder in each source file.")

    token = None
    installed_lua = OUTPUT / "init.lua"
    if installed_lua.exists():
        match = re.search(r'local BRIDGE_TOKEN = "([0-9a-f]{64})"', installed_lua.read_text())
        if match:
            token = match.group(1)
    token = token or secrets.token_hex(32)

    extension = OUTPUT / "edge-extension"
    extension.mkdir(parents=True, exist_ok=True)
    installed_lua.write_text(lua.replace(PLACEHOLDER, token))
    (extension / "background.js").write_text(worker.replace(PLACEHOLDER, token))
    for name in ("manifest.json", "options.html", "options.css", "options.js"):
        shutil.copy2(ROOT / "edge-extension" / name, extension / name)
    print("Prepared dist/init.lua and dist/edge-extension with a local bridge token.")
    print("Install dist/init.lua in Hammerspoon and load dist/edge-extension in Edge.")


if __name__ == "__main__":
    main()
