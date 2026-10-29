// Relays reply events from content scripts to the Tracky app (native messaging host "local.tracky").
const send = (msg) => chrome.runtime.sendNativeMessage("local.tracky", msg).catch((e) => console.warn("[tracky] app not reachable:", e.message));

send({ ping: true });   // check in each time Chrome starts this worker, so Tracky shows browser tracking as on
chrome.runtime.onMessage.addListener(send);
