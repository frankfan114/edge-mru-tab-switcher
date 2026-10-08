const BRIDGE = "http://127.0.0.1:27123";
const WS_URL = "ws://127.0.0.1:27123/ws";
const TOKEN = "__EDGE_MRU_LOCAL_TOKEN__";

const MIN_TABS = 2;
const MAX_TABS = 25;
const DEFAULT_TABS = 9;
const DEFAULT_SCOPE = "current";
const MRU_STORAGE_KEY = "mruTabsV2";
const LEGACY_MRU_STORAGE_KEY = "mruTabsV1";
const HISTORY_LIMIT = 100;

const PREVIEW_CAPTURE_DELAY_MS = 350;
const PREVIEW_MIN_INTERVAL_MS = 600;
const PREVIEW_CAPTURE_JPEG_QUALITY = 45;
const PREVIEW_OUTPUT_JPEG_QUALITY = 0.55;
const PREVIEW_MAX_WIDTH = 520;
const PREVIEW_MAX_HEIGHT = 320;
const PREVIEW_CACHE_LIMIT = 50;
const FAVICON_CACHE_LIMIT = 100;

let socket = null;
let reconnectTimer = null;
let heartbeatTimer = null;
let persistTimer = null;
let mruTabs = [];
let previewTimer = null;
let pendingPreviewTabId = null;
let lastPreviewCaptureAt = 0;
let previewCaptureInFlight = false;
const thumbnailCache = new Map();
const faviconCache = new Map();
const pendingFavicons = new Map();

function clampTabs(value) {
  let n = Number(value);
  if (!Number.isFinite(n)) n = DEFAULT_TABS;
  n = Math.floor(n);
  return Math.min(MAX_TABS, Math.max(MIN_TABS, n));
}

function normalizeScope(value) {
  return value === "all" ? "all" : "current";
}

async function getSettings() {
  const stored = await chrome.storage.sync.get({
    maxTabs: DEFAULT_TABS,
    tabScope: DEFAULT_SCOPE
  });
  return {
    maxTabs: clampTabs(stored.maxTabs),
    tabScope: normalizeScope(stored.tabScope)
  };
}

async function post(payload) {
  try {
    await fetch(`${BRIDGE}/edge-mru`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ token: TOKEN, ...payload })
    });
  } catch (_) {
    // Hammerspoon may be asleep/reloading. WebSocket reconnect will restore state.
  }
}

function sendSocket(payload) {
  if (!socket || socket.readyState !== WebSocket.OPEN) return false;
  try {
    socket.send(JSON.stringify({ token: TOKEN, ...payload }));
    return true;
  } catch (_) {
    return false;
  }
}

function normalizeMruEntry(tab) {
  return {
    tabId: Number(tab.id ?? tab.tabId),
    windowId: Number(tab.windowId),
    index: Number(tab.index ?? 0),
    title: String(tab.title || ""),
    url: String(tab.url || ""),
    favIconUrl: String(tab.favIconUrl || "")
  };
}

function schedulePersistMru() {
  if (persistTimer) clearTimeout(persistTimer);
  persistTimer = setTimeout(async () => {
    persistTimer = null;
    try {
      await chrome.storage.local.set({ [MRU_STORAGE_KEY]: mruTabs.slice(0, HISTORY_LIMIT) });
    } catch (_) {}
  }, 150);
}

function touchMru(tab) {
  if (!tab || tab.id == null || !tab.url) return;
  const entry = normalizeMruEntry(tab);
  mruTabs = [entry, ...mruTabs.filter((x) => x.tabId !== entry.tabId)].slice(0, HISTORY_LIMIT);
  schedulePersistMru();
}

function removeMru(tabId) {
  const id = Number(tabId);
  if (!Number.isInteger(id)) return;
  const next = mruTabs.filter((item) => item.tabId !== id);
  if (next.length !== mruTabs.length) {
    mruTabs = next;
    schedulePersistMru();
  }
}

async function refreshMruMetadata(tabId) {
  await mruReady;
  const id = Number(tabId);
  if (!Number.isInteger(id)) return;

  try {
    const tab = await chrome.tabs.get(id);
    const pos = mruTabs.findIndex((item) => item.tabId === id);
    if (pos >= 0) {
      mruTabs[pos] = normalizeMruEntry(tab);
      schedulePersistMru();
      await publishSnapshot();
      void publishFavicon(tab);
    }
  } catch (_) {}
}

async function reconcileSavedMru(saved) {
  const tabs = await chrome.tabs.query({});
  const byId = new Map(tabs.filter((t) => t.id != null).map((t) => [t.id, t]));
  const used = new Set();
  const restored = [];

  for (const old of Array.isArray(saved) ? saved : []) {
    let tab = byId.get(Number(old.tabId));

    if (!tab) {
      tab = tabs.find((t) => !used.has(t.id) && t.url === old.url && t.title === old.title);
    }
    if (!tab) {
      tab = tabs.find((t) => !used.has(t.id) && t.url === old.url);
    }

    if (tab && tab.id != null && tab.url) {
      used.add(tab.id);
      restored.push(normalizeMruEntry(tab));
      if (restored.length >= HISTORY_LIMIT) break;
    }
  }

  // Add currently open tabs not represented by persisted history at the tail.
  for (const tab of tabs) {
    if (tab.id != null && tab.url && !used.has(tab.id)) {
      restored.push(normalizeMruEntry(tab));
      if (restored.length >= HISTORY_LIMIT) break;
    }
  }

  return restored;
}

const mruReady = (async () => {
  try {
    const stored = await chrome.storage.local.get({
      [MRU_STORAGE_KEY]: [],
      [LEGACY_MRU_STORAGE_KEY]: []
    });
    const saved = Array.isArray(stored[MRU_STORAGE_KEY]) && stored[MRU_STORAGE_KEY].length
      ? stored[MRU_STORAGE_KEY]
      : stored[LEGACY_MRU_STORAGE_KEY];
    mruTabs = await reconcileSavedMru(saved);
    schedulePersistMru();
  } catch (_) {
    mruTabs = [];
  }
})();

async function publishSettings() {
  const settings = await getSettings();
  sendSocket({ type: "settings", ...settings });
}

async function publishSnapshot() {
  await mruReady;
  sendSocket({ type: "mruSnapshot", tabs: mruTabs.slice(0, HISTORY_LIMIT) });
}

async function publishFocusedWindow() {
  try {
    const win = await chrome.windows.getLastFocused();
    if (win && win.id != null) {
      sendSocket({ type: "focusedWindow", windowId: win.id });
      await post({ type: "focusedWindow", windowId: win.id });
    }
  } catch (_) {}
}

async function publishTab(tabId, type = "activated") {
  try {
    const tab = await chrome.tabs.get(Number(tabId));
    if (!tab || tab.id == null || !tab.url) return;

    touchMru(tab);

    let windowFocused = false;
    try {
      const win = await chrome.windows.get(tab.windowId);
      windowFocused = Boolean(win?.focused);
    } catch (_) {}

    await post({
      type,
      tabId: tab.id,
      windowId: tab.windowId,
      index: tab.index,
      title: tab.title || "",
      url: tab.url || "",
      windowFocused
    });
    void publishFavicon(tab);
  } catch (_) {}
}

async function publishFocusedTab(type = "focusChanged", explicitWindowId = null) {
  try {
    let tabs;
    if (explicitWindowId != null && explicitWindowId !== chrome.windows.WINDOW_ID_NONE) {
      tabs = await chrome.tabs.query({ active: true, windowId: explicitWindowId });
    } else {
      tabs = await chrome.tabs.query({ active: true, lastFocusedWindow: true });
    }

    if (tabs[0]?.id != null) {
      await publishTab(tabs[0].id, type);
      sendSocket({ type: "focusedWindow", windowId: tabs[0].windowId });
      await post({ type: "focusedWindow", windowId: tabs[0].windowId });
      scheduleThumbnailCapture(tabs[0].id);
      void publishFaviconsForScope();
    }
  } catch (_) {}
}

function rememberThumbnail(tabId, dataUrl) {
  const id = Number(tabId);
  if (!Number.isInteger(id) || typeof dataUrl !== "string" || !dataUrl.startsWith("data:image/")) return;
  thumbnailCache.delete(id);
  thumbnailCache.set(id, dataUrl);
  while (thumbnailCache.size > PREVIEW_CACHE_LIMIT) {
    thumbnailCache.delete(thumbnailCache.keys().next().value);
  }
}

function arrayBufferToDataUrl(buffer, mimeType) {
  const bytes = new Uint8Array(buffer);
  const chunkSize = 0x8000;
  let binary = "";
  for (let i = 0; i < bytes.length; i += chunkSize) {
    binary += String.fromCharCode(...bytes.subarray(i, i + chunkSize));
  }
  return `data:${mimeType};base64,${btoa(binary)}`;
}

function faviconKey(tab) {
  return JSON.stringify([String(tab.url || ""), String(tab.favIconUrl || "")]);
}

async function publishFavicon(tab) {
  const id = Number(tab.id ?? tab.tabId);
  if (!Number.isInteger(id) || !tab.url) return;
  const key = faviconKey(tab);
  const cached = faviconCache.get(id);
  if (cached?.key === key) {
    faviconCache.delete(id);
    faviconCache.set(id, cached);
    sendSocket({ type: "favicon", tabId: id, dataUrl: cached.dataUrl });
    return;
  }
  const pending = pendingFavicons.get(id);
  if (pending?.key === key) return pending.promise;

  // The browser favicon endpoint supplies a small PNG from its own icon cache.
  const request = { key };
  pendingFavicons.set(id, request);
  request.promise = (async () => {
    try {
      const url = new URL(chrome.runtime.getURL("/_favicon/"));
      url.searchParams.set("pageUrl", tab.url);
      url.searchParams.set("size", "32");
      const response = await fetch(url.toString(), { signal: AbortSignal.timeout(3000) });
      if (!response.ok) return;
      const blob = await response.blob();
      if (blob.type !== "image/png" || blob.size > 64 * 1024) return;
      const dataUrl = arrayBufferToDataUrl(await blob.arrayBuffer(), "image/png");
      const current = mruTabs.find((item) => item.tabId === id);
      if (pendingFavicons.get(id) !== request || !current || faviconKey(current) !== key) return;
      faviconCache.delete(id);
      faviconCache.set(id, { key, dataUrl });
      while (faviconCache.size > FAVICON_CACHE_LIMIT) {
        faviconCache.delete(faviconCache.keys().next().value);
      }
      sendSocket({ type: "favicon", tabId: id, dataUrl });
    } catch (_) {
      // A failed lookup leaves the native switcher's fallback icon in place.
    } finally {
      if (pendingFavicons.get(id) === request) pendingFavicons.delete(id);
    }
  })();
  return request.promise;
}

async function publishFaviconsForScope() {
  await mruReady;
  const { maxTabs, tabScope } = await getSettings();
  const focused = await chrome.windows.getLastFocused().catch(() => null);
  const tabs = mruTabs.filter((tab) => tabScope === "all" || !focused || tab.windowId === focused.id);
  await Promise.all(tabs.slice(0, maxTabs).map(publishFavicon));
}

async function makeSmallThumbnail(dataUrl) {
  const sourceBlob = await (await fetch(dataUrl)).blob();
  const bitmap = await createImageBitmap(sourceBlob);
  try {
    const scale = Math.min(1, PREVIEW_MAX_WIDTH / bitmap.width, PREVIEW_MAX_HEIGHT / bitmap.height);
    const width = Math.max(1, Math.round(bitmap.width * scale));
    const height = Math.max(1, Math.round(bitmap.height * scale));
    const canvas = new OffscreenCanvas(width, height);
    const context = canvas.getContext("2d", { alpha: false });
    if (!context) throw new Error("2D OffscreenCanvas unavailable");
    context.drawImage(bitmap, 0, 0, width, height);
    const outputBlob = await canvas.convertToBlob({
      type: "image/jpeg",
      quality: PREVIEW_OUTPUT_JPEG_QUALITY
    });
    return arrayBufferToDataUrl(await outputBlob.arrayBuffer(), outputBlob.type || "image/jpeg");
  } finally {
    if (typeof bitmap.close === "function") bitmap.close();
  }
}

async function captureThumbnail(tabId) {
  const id = Number(tabId);
  if (!Number.isInteger(id)) return;

  if (previewCaptureInFlight) {
    scheduleThumbnailCapture(id, 150);
    return;
  }

  previewCaptureInFlight = true;
  try {
    const tab = await chrome.tabs.get(id);
    if (!tab?.active) return;
    const win = await chrome.windows.get(tab.windowId);
    if (!win?.focused) return;

    lastPreviewCaptureAt = Date.now();
    const captured = await chrome.tabs.captureVisibleTab(tab.windowId, {
      format: "jpeg",
      quality: PREVIEW_CAPTURE_JPEG_QUALITY
    });
    if (!captured) return;

    const small = await makeSmallThumbnail(captured);
    const current = await chrome.tabs.get(id);
    const currentWindow = await chrome.windows.get(current.windowId);
    if (!current.active || !currentWindow.focused) return;

    rememberThumbnail(id, small);
    sendSocket({ type: "thumbnail", tabId: id, dataUrl: small });
  } catch (_) {
    // Protected edge:// pages or file:// URLs without file access simply have no preview.
  } finally {
    previewCaptureInFlight = false;
  }
}

function scheduleThumbnailCapture(tabId, extraDelay = 0) {
  const id = Number(tabId);
  if (!Number.isInteger(id)) return;

  pendingPreviewTabId = id;
  if (previewTimer) clearTimeout(previewTimer);

  const elapsed = Date.now() - lastPreviewCaptureAt;
  const throttleDelay = Math.max(0, PREVIEW_MIN_INTERVAL_MS - elapsed);
  const delay = Math.max(PREVIEW_CAPTURE_DELAY_MS + extraDelay, throttleDelay);

  previewTimer = setTimeout(() => {
    previewTimer = null;
    const target = pendingPreviewTabId;
    pendingPreviewTabId = null;
    void captureThumbnail(target);
  }, delay);
}

async function publishCachedThumbnails() {
  await mruReady;
  const { maxTabs, tabScope } = await getSettings();
  const focused = await chrome.windows.getLastFocused().catch(() => null);
  const focusedId = focused?.id;
  let sent = 0;

  for (const entry of mruTabs) {
    if (tabScope === "current" && focusedId != null && entry.windowId !== focusedId) continue;
    const dataUrl = thumbnailCache.get(entry.tabId);
    if (dataUrl) {
      sendSocket({ type: "thumbnail", tabId: entry.tabId, dataUrl });
      sent += 1;
      if (sent >= maxTabs) break;
    }
  }
}

function scheduleReconnect() {
  if (reconnectTimer) return;
  reconnectTimer = setTimeout(() => {
    reconnectTimer = null;
    connectSocket();
  }, 750);
}

function startHeartbeat() {
  if (heartbeatTimer) clearInterval(heartbeatTimer);
  heartbeatTimer = setInterval(() => {
    if (!sendSocket({ type: "heartbeat", ts: Date.now() })) {
      try { socket?.close(); } catch (_) {}
      scheduleReconnect();
    }
  }, 5000);
}

function connectSocket() {
  try {
    if (socket && (socket.readyState === WebSocket.OPEN || socket.readyState === WebSocket.CONNECTING)) return;
    socket = new WebSocket(WS_URL);

    socket.onopen = async () => {
      startHeartbeat();
      sendSocket({ type: "heartbeat", ts: Date.now() });
      await mruReady;
      await publishSettings();
      await publishFocusedWindow();
      await publishSnapshot();
      void publishFaviconsForScope();
      await publishCachedThumbnails();
      await publishFocusedTab("focusChanged");
    };

    socket.onmessage = async (event) => {
      let msg;
      try { msg = JSON.parse(event.data); } catch (_) { return; }
      if (!msg || msg.token !== TOKEN) return;

      if (msg.type === "switchTab") {
        const requestId = String(msg.requestId || "");
        const tabId = Number(msg.tabId);
        let ok = false;
        let error = "";

        try {
          const tab = await chrome.tabs.get(tabId);
          await chrome.tabs.update(tabId, { active: true });
          await chrome.windows.update(tab.windowId, { focused: true });
          ok = true;
        } catch (err) {
          error = String(err?.message || err || "switch failed");
        }

        sendSocket({ type: "switchResult", requestId, ok, error });
      }
    };

    socket.onclose = () => {
      socket = null;
      scheduleReconnect();
    };

    socket.onerror = () => {
      try { socket?.close(); } catch (_) {}
    };
  } catch (_) {
    socket = null;
    scheduleReconnect();
  }
}

chrome.tabs.onActivated.addListener(({ tabId }) => {
  void publishTab(tabId, "activated");
  scheduleThumbnailCapture(tabId);
});

chrome.tabs.onUpdated.addListener((tabId, changeInfo, tab) => {
  if (changeInfo.favIconUrl !== undefined || changeInfo.url !== undefined || changeInfo.title !== undefined) {
    void refreshMruMetadata(tabId);
  }
  if (!tab.active) return;
  if (changeInfo.url !== undefined || changeInfo.title !== undefined) {
    void publishTab(tabId, "updated");
  }
  if (changeInfo.status === "complete") {
    scheduleThumbnailCapture(tabId, 150);
  }
});

chrome.tabs.onRemoved.addListener((tabId) => {
  void (async () => {
    await mruReady;
    removeMru(tabId);
    thumbnailCache.delete(Number(tabId));
    faviconCache.delete(Number(tabId));
    pendingFavicons.delete(Number(tabId));
    await post({ type: "removed", tabId });
    await publishSnapshot();
  })();
});

chrome.tabs.onAttached.addListener((tabId) => {
  // Moving a tab between windows changes windowId but should not make the tab
  // artificially "most recent". Preserve its MRU position and update metadata.
  void refreshMruMetadata(tabId);
});

chrome.tabs.onMoved.addListener((tabId) => {
  void refreshMruMetadata(tabId);
});

chrome.windows.onFocusChanged.addListener((windowId) => {
  if (windowId === chrome.windows.WINDOW_ID_NONE) return;
  void (async () => {
    await publishFocusedTab("focusChanged", windowId);
    await publishCachedThumbnails();
  })();
});

chrome.storage.onChanged.addListener((changes, areaName) => {
  if (areaName !== "sync") return;
  if (changes.maxTabs || changes.tabScope) {
    void publishSettings();
    void publishCachedThumbnails();
    void publishFaviconsForScope();
  }
});

chrome.runtime.onStartup.addListener(() => connectSocket());
chrome.runtime.onInstalled.addListener(() => connectSocket());

void mruReady.then(() => connectSocket());
