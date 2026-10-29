// General meter for AI chat sites that have no dedicated watcher in content.js. Runs inside the
// page (MAIN world) so it can see the page's own requests.
//
// It never reads what is sent or streamed. It only notices that a reply is streaming (a POST whose
// response arrives in pieces, over fetch or XMLHttpRequest), then measures how much visible text the
// page gained from the start of the stream until it settles. Overlapping streams count as one reply.
// The model is taken from the request's "model" field when the site sends one.
// ponytail: WebSocket chats are not seen; add a WebSocket hook if a listed site turns out to use one.
(() => {
  const SETTLE_MS = 1500, MIN_CHARS = 20, CHARS_PER_TOKEN = 4;
  let open = false, active = 0, startLen = 0, model = null, timer;
  const visible = () => document.body?.innerText.length ?? 0;

  function modelOf(body) {
    try {
      const j = typeof body === "string" ? JSON.parse(body) : null;
      const m = j?.model ?? j?.model_slug ?? j?.models?.[0];
      return typeof m === "string" ? m.toLowerCase() : null;
    } catch { return null; }
  }
  function begin(m, from) {   // from: visible text length when the request was sent
    clearTimeout(timer);
    if (!open) { open = true; startLen = from; model = null; }
    model ||= m;
    active++;
  }
  function end() {
    if (--active > 0) return;
    timer = setTimeout(() => {
      open = false;
      const chars = visible() - startLen;
      if (chars >= MIN_CHARS) {
        window.postMessage({ tracky: { site: location.hostname, model, tokens: Math.round(chars / CHARS_PER_TOKEN) } }, location.origin);
      }
    }, SETTLE_MS);
  }

  const origFetch = window.fetch;
  window.fetch = async function (input, init) {
    let post = false, from = 0;
    try {   // never let the meter break the site: anything unexpected passes straight through
      post = String(init?.method ?? (input instanceof Request ? input.method : "GET")).toUpperCase() === "POST";
      if (post) from = visible();   // reading visible text forces a layout, so only for POSTs
    } catch {}
    const res = await origFetch.apply(this, arguments);
    try {
      if (post && res.body && /event-stream|ndjson|stream/.test(res.headers.get("content-type") ?? "")) {
        begin(modelOf(init?.body), from);
        res.clone().body.pipeTo(new WritableStream()).catch(() => {}).finally(end);   // waits for the end only
      }
    } catch {}
    return res;
  };

  const xhrOpen = XMLHttpRequest.prototype.open, xhrSend = XMLHttpRequest.prototype.send;
  XMLHttpRequest.prototype.open = function (method) {
    this.trackyPost = String(method).toUpperCase() === "POST";
    return xhrOpen.apply(this, arguments);
  };
  XMLHttpRequest.prototype.send = function (body) {
    if (this.trackyPost) {
      let chunks = 0, began = false;
      const from = visible();
      this.addEventListener("progress", () => { if (++chunks === 2) { began = true; begin(modelOf(body), from); } });   // streaming = several pieces
      this.addEventListener("loadend", () => { if (began) end(); });
    }
    return xhrSend.apply(this, arguments);
  };
})();
