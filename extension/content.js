// Watches AI replies on the page and reports each finished one to Tracky: site, model and an
// approximate token count. Reply text never leaves the page.
//
// A reply counts once it has been seen growing (streaming) and then stops changing for a poll.
// Replies that appear already complete (history, an old chat opened) are never counted.
// ponytail: a reply that streams in under one poll interval is missed; poll faster if that matters.

const POLL_MS = 1000;
const CHARS_PER_TOKEN = 4; // common rule of thumb for English text

const SITES = {
  "claude.ai": {
    replies: "[data-is-streaming]",
    // The model picker's label, e.g. "Opus 5.5" → "claude-opus-5-5".
    model: () => {
      for (const b of document.querySelectorAll("button")) {
        const m = b.textContent.match(/\b(Opus|Sonnet|Haiku|Fable)\s+(\d+(?:\.\d+)?)/);
        if (m) return `claude-${m[1].toLowerCase()}-${m[2].replace(".", "-")}`;
      }
      return null;
    },
  },
  "chatgpt.com": {
    // 2026 markup is data-message-role; the older data-message-author-role is kept as a fallback.
    replies: '[data-message-role="assistant"], [data-message-author-role="assistant"]',
    text: (el) => (el.querySelector("[data-assistant-markdown-root]") ?? el).textContent,
    // Logged-out pages show no model; logged in, look for one on the reply or in the picker ("GPT-5.2").
    model: (el) => {
      if (el.dataset.messageModelSlug) return el.dataset.messageModelSlug;
      for (const b of document.querySelectorAll("button")) {
        const m = b.textContent.match(/\bGPT[- ]?(\d+(?:\.\d+)?)(?:[- ](mini|nano))?/i);
        if (m) return ["gpt", m[1], m[2]].filter(Boolean).join("-").toLowerCase();
      }
      return null;
    },
  },
  "gemini.google.com": {
    replies: "model-response",
    model: () => null,
  },
};

function report(event) {
  console.debug("[tracky]", event);
  chrome.runtime.sendMessage(event).catch(() => {});
}

function watchReplies(site, cfg) {
  const seen = new WeakMap(); // element → { len, grew, reported }
  let first = true;
  setInterval(() => {
    for (const el of document.querySelectorAll(cfg.replies)) {
      const len = (cfg.text ? cfg.text(el) : el.textContent).length;
      const s = seen.get(el);
      if (!s) {
        // Present on the first poll = history; new but non-empty is fine, it can still grow.
        seen.set(el, { len, grew: false, reported: first ? len : 0 });
        continue;
      }
      if (len > s.len) { s.grew = true; s.len = len; continue; }
      if (s.grew && len === s.len && len > s.reported) {
        report({ site, model: cfg.model(el), tokens: Math.round((len - s.reported) / CHARS_PER_TOKEN) });
        s.reported = len;
      }
    }
    first = false;
  }, POLL_MS);
}

// Google search: every AI answer is one prompt. An AI Overview has a heading of its own, and each
// AI Mode answer (including follow-ups and "dive deeper" from an overview) has a heading like
// "AI Mode reply for …". A page can show an overview and its first reply heading together, so a
// page counts the larger of the two. Labels are localized: English and Italian are checked against
// google.com (Oct 2026), the others are best guesses.
const OVERVIEW = /^(AI Overview|Overview dell'AI|Aperçu IA|Übersicht mit KI|Resumen de IA|Visão geral criada por IA)$/;
const REPLY = /^(AI Mode reply for|Risposta di AI Mode per|Réponse du mode IA pour|Antwort im KI-Modus für|Respuesta del Modo IA para)\b/;

function watchSearch() {
  let counted = 0;
  setInterval(() => {
    let overview = 0, replies = 0;
    for (const h of document.querySelectorAll("h1, h2, h3, [role=heading]")) {
      const t = h.textContent.trim();
      if (OVERVIEW.test(t)) overview = 1;
      else if (REPLY.test(t)) replies++;
    }
    const answers = Math.max(overview, replies);
    for (; counted < answers; counted++) report({ site: "google-ai-overview", model: null, tokens: 0 });
    counted = answers;   // a new results page in place starts over
  }, POLL_MS);
}

if (location.hostname === "www.google.com") watchSearch();
else if (SITES[location.hostname]) watchReplies(location.hostname, SITES[location.hostname]);
else {
  // Any other listed AI site: meter.js (in the page) measures replies; pass its events on.
  window.addEventListener("message", (e) => {
    if (e.source === window && e.data?.tracky) report(e.data.tracky);
  });
}
