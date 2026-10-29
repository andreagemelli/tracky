// Relays reply events from content scripts to the Tracky app (native messaging host "local.tracky").
chrome.runtime.onMessage.addListener((event) => {
  chrome.runtime.sendNativeMessage("local.tracky", event).catch((e) => console.warn("[tracky] app not reachable:", e.message));
});
