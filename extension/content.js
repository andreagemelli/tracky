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
    replies: '[data-message-author-role="assistant"]',
    model: (el) => el.dataset.messageModelSlug || null,
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
      const len = el.textContent.length;
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

// Google search: one AI Overview (or AI Mode answer) per results page. Labels are localized.
const OVERVIEW = /^(AI Overview|AI Mode|Panoramica AI|Modalità AI|Aperçu IA|Mode IA|Übersicht mit KI|KI-Modus|Resumen de IA|Modo IA|Visão geral criada por IA)$/;

function watchSearch() {
  let reportedFor = null;
  setInterval(() => {
    if (reportedFor === location.href) return;
    for (const h of document.querySelectorAll("h1, h2, h3, [role=heading]")) {
      if (OVERVIEW.test(h.textContent.trim())) {
        report({ site: "google-ai-overview", model: null, tokens: 0 });
        reportedFor = location.href;
        return;
      }
    }
  }, POLL_MS);
}

if (location.hostname === "www.google.com") watchSearch();
else if (SITES[location.hostname]) watchReplies(location.hostname, SITES[location.hostname]);
