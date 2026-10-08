const maxTabs = document.getElementById("maxTabs");
const maxTabsValue = document.getElementById("maxTabsValue");
const tabScope = document.getElementById("tabScope");
const status = document.getElementById("status");
let statusTimer = null;

function clamp(value) {
  const n = Math.floor(Number(value) || 9);
  return Math.min(25, Math.max(2, n));
}

function showSaved() {
  status.textContent = "Saved";
  if (statusTimer) clearTimeout(statusTimer);
  statusTimer = setTimeout(() => { status.textContent = ""; }, 900);
}

async function load() {
  const stored = await chrome.storage.sync.get({ maxTabs: 9, tabScope: "current" });
  maxTabs.value = clamp(stored.maxTabs);
  maxTabsValue.value = maxTabs.value;
  tabScope.value = stored.tabScope === "all" ? "all" : "current";
}

maxTabs.addEventListener("input", () => {
  maxTabsValue.value = maxTabs.value;
});

maxTabs.addEventListener("change", async () => {
  const value = clamp(maxTabs.value);
  await chrome.storage.sync.set({ maxTabs: value });
  showSaved();
});

tabScope.addEventListener("change", async () => {
  const value = tabScope.value === "all" ? "all" : "current";
  await chrome.storage.sync.set({ tabScope: value });
  showSaved();
});

void load();
