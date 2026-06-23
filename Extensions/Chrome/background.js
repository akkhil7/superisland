const NATIVE_HOST = "com.superisland.chrome_bridge";

let nativePort = null;
const documentIds = new Map();

function connectNative() {
  try {
    nativePort = chrome.runtime.connectNative(NATIVE_HOST);
    nativePort.onMessage.addListener(handleNativeMessage);
    nativePort.onDisconnect.addListener(() => {
      nativePort = null;
      setTimeout(connectNative, 1500);
    });
  } catch {
    nativePort = null;
  }
}

function postNative(message) {
  if (!nativePort) return;
  try {
    nativePort.postMessage(message);
  } catch {
    nativePort = null;
  }
}

async function captureTabState(tabId) {
  if (!tabId || tabId === chrome.tabs.TAB_ID_NONE) return;

  let tab;
  try {
    tab = await chrome.tabs.get(tabId);
  } catch {
    return;
  }

  let domSummary = null;
  try {
    domSummary = await chrome.tabs.sendMessage(tabId, { type: "superisland_collect_dom" });
  } catch {
    domSummary = {
      title: tab.title || "",
      text: "",
      taskState: "unknown"
    };
  }

  postNative({
    type: "tab_state",
    tab: {
      tabId: tab.id,
      windowId: tab.windowId,
      index: tab.index,
      url: tab.url || "",
      title: tab.title || "",
      documentId: documentIds.get(tab.id) || null,
      status: domSummary?.taskState || "unknown"
    },
    domSummary
  });
}

async function handleNativeMessage(message) {
  const commands = Array.isArray(message?.commands) ? message.commands : [];
  for (const command of commands) {
    if (command.type !== "refocus_tab" || typeof command.tabId !== "number") continue;
    try {
      if (typeof command.windowId === "number") {
        await chrome.windows.update(command.windowId, { focused: true });
      }
      await chrome.tabs.update(command.tabId, { active: true });
    } catch {
      // The native app will fall back to AppleScript/AX when the tab is gone.
    }
  }
}

chrome.tabs.onActivated.addListener(({ tabId }) => {
  captureTabState(tabId);
});

chrome.tabs.onUpdated.addListener((tabId, changeInfo) => {
  if (changeInfo.status === "complete" || changeInfo.title || changeInfo.url) {
    captureTabState(tabId);
  }
});

chrome.windows.onFocusChanged.addListener(async (windowId) => {
  if (windowId === chrome.windows.WINDOW_ID_NONE) return;
  const [tab] = await chrome.tabs.query({ active: true, windowId });
  if (tab?.id) captureTabState(tab.id);
});

chrome.webNavigation.onCommitted.addListener((details) => {
  if (details.frameId === 0 && details.documentId) {
    documentIds.set(details.tabId, details.documentId);
  }
});

chrome.runtime.onMessage.addListener((message, sender) => {
  if (message?.type !== "superisland_dom_state" || !sender.tab?.id) return;
  captureTabState(sender.tab.id);
});

setInterval(() => {
  postNative({ type: "command_poll" });
}, 1000);

connectNative();
