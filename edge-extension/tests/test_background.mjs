import assert from "node:assert/strict";
import fs from "node:fs/promises";
import path from "node:path";
import vm from "node:vm";
import { Blob, Buffer } from "node:buffer";

export async function runTests(root) {
  const source = await fs.readFile(path.join(root, "background.js"), "utf8");
  const manifest = JSON.parse(await fs.readFile(path.join(root, "manifest.json"), "utf8"));
  assert(manifest.permissions.includes("favicon"));
  const tabs = Array.from({ length: 12 }, (_, i) => ({
    id: i + 1, windowId: i < 9 ? 1 : 2, index: i, title: `Tab ${i + 1}`,
    url: `https://example.com/${i + 1}`, favIconUrl: `https://example.com/icon${i + 1}.png`, active: i === 0,
  }));
  const listeners = {};
  const messages = [];
  const faviconRequests = [];
  let fetchFavicon = async () => ({ ok: true, blob: async () => new Blob(["png"], { type: "image/png" }) });
  let settings = { maxTabs: 9, tabScope: "current" };
  const event = (name) => ({ addListener(callback) { listeners[name] = callback; } });
  class Socket {
    static OPEN = 1;
    static CONNECTING = 0;
    readyState = 1;
    send(message) { messages.push(JSON.parse(message)); }
    close() { this.readyState = 3; }
  }
  const context = vm.createContext({
    URL, Blob, AbortSignal, WebSocket: Socket,
    btoa: (value) => Buffer.from(value, "binary").toString("base64"),
    setTimeout: () => 1, clearTimeout() {}, setInterval: () => 1, clearInterval() {},
    fetch: async (url) => {
      if (String(url).includes("/_favicon/")) {
        faviconRequests.push(String(url));
        return fetchFavicon(url);
      }
      return { ok: true };
    },
    chrome: {
      runtime: { getURL: (url) => `chrome-extension://test${url}`,
        onStartup: event("startup"), onInstalled: event("installed") },
      storage: {
        local: { get: async (defaults) => defaults, set: async () => {} },
        sync: { get: async () => settings }, onChanged: event("settings"),
      },
      tabs: {
        query: async (query) => tabs.filter((tab) => (!query.active || tab.active)
          && (query.windowId == null || tab.windowId === query.windowId)),
        get: async (id) => { const tab = tabs.find((item) => item.id === id); assert(tab); return tab; },
        onActivated: event("activated"), onUpdated: event("updated"), onRemoved: event("removed"),
        onAttached: event("attached"), onMoved: event("moved"),
      },
      windows: { getLastFocused: async () => ({ id: 1 }), get: async () => ({ focused: true }),
        onFocusChanged: event("focused"), WINDOW_ID_NONE: -1 },
    },
  });
  new vm.Script(source).runInContext(context);
  const api = vm.runInContext(`({
    ready: mruReady, favicon: publishFavicon, scope: publishFaviconsForScope,
    state: () => ({ mruTabs, faviconCache, pendingFavicons }),
    setMru: (tabs) => { mruTabs = tabs.map(normalizeMruEntry); },
    refresh: refreshMruMetadata,
  })`, context);
  await api.ready;
  await Promise.resolve(); // Initial socket setup.

  await api.favicon(tabs[0]);
  assert.equal(faviconRequests.length, 1);
  const url = new URL(faviconRequests[0]);
  assert.equal(url.searchParams.get("pageUrl"), tabs[0].url);
  assert.equal(url.searchParams.get("size"), "32");
  assert(messages.some((message) => message.type === "favicon" && message.tabId === 1
    && message.dataUrl.startsWith("data:image/png;base64,")));
  await api.favicon(tabs[0]);
  assert.equal(faviconRequests.length, 1, "Cached icons should not fetch again");

  let resolveFetch;
  fetchFavicon = () => new Promise((resolve) => { resolveFetch = resolve; });
  const first = api.favicon(tabs[1]);
  const duplicate = api.favicon(tabs[1]);
  assert.equal(faviconRequests.length, 2, "Concurrent requests for one tab should be deduplicated");
  const png = { ok: true, blob: async () => new Blob(["png"], { type: "image/png" }) };
  resolveFetch(png);
  await Promise.all([first, duplicate]);
  assert.equal(api.state().pendingFavicons.size, 0);

  // Navigation during a fetch must not attach an old icon to the new page.
  const stale = api.favicon(tabs[2]);
  tabs[2].url = "https://different.example/";
  api.setMru(tabs);
  resolveFetch(png); await stale;
  assert(!api.state().faviconCache.has(3));

  // A closed tab must not be reinserted when a request completes.
  const closing = api.favicon(tabs[3]);
  const completeClosed = resolveFetch;
  listeners.removed(4);
  await Promise.resolve(); await Promise.resolve();
  completeClosed(png); await closing;
  assert(!api.state().faviconCache.has(4));
  assert(!api.state().pendingFavicons.has(4));

  // A newer request wins when an old one finishes afterwards.
  const older = api.favicon(tabs[4]);
  const completeOlder = resolveFetch;
  tabs[4].favIconUrl = "https://example.com/replacement.png";
  api.setMru(tabs);
  const newer = api.favicon(tabs[4]);
  const completeNewer = resolveFetch;
  completeNewer(png); await newer;
  const newKey = api.state().faviconCache.get(5).key;
  completeOlder(png); await older;
  assert.equal(api.state().faviconCache.get(5).key, newKey);

  for (const response of [
    { ok: false },
    { ok: true, blob: async () => new Blob(["html"], { type: "text/html" }) },
    { ok: true, blob: async () => new Blob([new Uint8Array(65537)], { type: "image/png" }) },
  ]) {
    fetchFavicon = async () => response;
    await api.favicon(tabs[5]);
    assert(!api.state().faviconCache.has(6));
    assert(!api.state().pendingFavicons.has(6));
  }
  fetchFavicon = async () => { throw new Error("Unavailable"); };
  await api.favicon(tabs[5]);
  assert(!api.state().pendingFavicons.has(6));

  // Scope and display count apply to the initial icon population.
  api.state().faviconCache.clear();
  faviconRequests.length = 0;
  api.setMru(tabs);
  settings = { maxTabs: 3, tabScope: "current" };
  fetchFavicon = async () => png;
  await api.scope();
  assert.equal(faviconRequests.length, 3);
  assert.deepEqual([...api.state().faviconCache.keys()], [1, 2, 3]);
  api.state().faviconCache.clear();
  settings = { maxTabs: 12, tabScope: "all" };
  await api.scope();
  assert.equal(api.state().faviconCache.size, 12);

  // Background tab metadata updates should preserve its MRU position.
  const order = api.state().mruTabs.map((tab) => tab.tabId).join(",");
  tabs[7].favIconUrl = "https://example.com/changed.png";
  await api.refresh(8);
  assert.equal(api.state().mruTabs.map((tab) => tab.tabId).join(","), order);
  const pending = api.state().pendingFavicons.get(8);
  if (pending) await pending.promise;
  assert(api.state().faviconCache.get(8).key.includes("changed.png"));

  const manyTabs = Array.from({ length: 101 }, (_, i) => ({ id: i + 100,
    url: `https://cache.example/${i}`, windowId: 1, title: `Cache ${i}` }));
  api.setMru(manyTabs);
  api.state().faviconCache.clear();
  for (const tab of manyTabs) await api.favicon(tab);
  assert.equal(api.state().faviconCache.size, 100);
  assert(!api.state().faviconCache.has(100));
  assert(api.state().faviconCache.has(200));
  return "JavaScript checks passed: icon transport, caching, races, scope, metadata, and failures";
}
