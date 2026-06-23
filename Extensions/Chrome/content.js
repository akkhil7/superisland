function taskStateFromText(text) {
  const value = (text || "").toLowerCase();
  if (/(stop generating|thinking|running|working|in progress|generating)/.test(value)) {
    return "working";
  }
  if (/(failed|error|approve|confirm|continue\?|waiting for|needs input|password)/.test(value)) {
    return "needsAttention";
  }
  if (/(done|completed|finished|success|all tests passed|build complete)/.test(value)) {
    return "done";
  }
  return "unknown";
}

function collectDOMSummary() {
  const text = (document.body?.innerText || "").replace(/\s+/g, " ").trim().slice(0, 6000);
  return {
    title: document.title || "",
    text,
    taskState: taskStateFromText(text)
  };
}

chrome.runtime.onMessage.addListener((message, _sender, sendResponse) => {
  if (message?.type === "superisland_collect_dom") {
    sendResponse(collectDOMSummary());
  }
  return true;
});

let pending = null;
const observer = new MutationObserver(() => {
  clearTimeout(pending);
  pending = setTimeout(() => {
    chrome.runtime.sendMessage({ type: "superisland_dom_state" }).catch(() => {});
  }, 650);
});

if (document.body) {
  observer.observe(document.body, {
    childList: true,
    subtree: true,
    characterData: true
  });
}
