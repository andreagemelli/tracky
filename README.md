# Tracky

A small pixel water drop that lives on your Mac and shows how much water your AI use costs, while you use it. It works locally out of the box, reading the logs AI tools already keep on your Mac. Browser tracking (AI chats and Google's AI answers) is an optional add-on.

![Tracky at each heat level, awake in light mode and asleep in dark mode, with sample usage in the legend](docs/preview.png)

- **On the desktop:** a card you can drag anywhere. Tracky sleeps when no AI is working and paces and hops while one is. Double-click the card (or use the menu) to switch between the complete card and a minimal one with just Tracky and the total.
- **It heats up as you use more water.** A bar fills toward the next container, and each container you pass makes Tracky hotter:

  | Container | Liters | Tracky |
  |---|---|---|
  | cup | 0.25 | happy |
  | bottle | 1.5 | blushing |
  | toilet flush | 6 ([US limit, 1.6 gal](https://www.epa.gov/watersense/residential-toilets)) | a drop of sweat |
  | bucket | 10 | sweating, flushed, panting |
  | shower | 60 ([average US shower, 15.8 gal](https://home-water-works.org/indoor-use/showers)) | steaming |
  | bathtub | 150 | overheated, red |

- **Where the water comes from:** a second bar splits the total by model and source, such as *Opus 5.5 · Code*, *GPT 5.2 · ChatGPT* or *Google AI Overview*, with a legend. The four largest get a color; the rest are grouped as *Other*.
- **Tips in a speech bubble,** about what you used last: the next lighter model in the same family (*Try Sonnet 5.5: ~3× less water* after Opus), your coding agent's effort (*45% thinking: try lower effort*), or, after a Google search with an AI answer, *Use Google's Web tab: no AI answer*.
- **Browser tracking, at a glance:** a globe in the card's corner with a red dot when it's off and a green one when it's on. Click it to set it up in two steps.
- **Menu bar:** the drop and the total. Click it for the same breakdown, a tip, the period (last 1, 5 or 24 hours), switches for the minimal card, to hide the card and to open Tracky at login (on by default), and *How is this estimated?*, which opens the EcoLogits method Tracky implements.

Everything stays on your Mac. Tracky records only which model ran, when, and how many tokens it produced. It never stores prompts or replies, needs no macOS permissions and makes no network calls.

## What works, and what's been tested

Tracky may work with tools outside this list, but only what's marked *tested* has been checked against real use.

| Source | How Tracky sees it | Status |
|---|---|---|
| Claude Code (terminal, and the Claude desktop app's Code tab) | its local logs: exact model and token counts | tested |
| claude.ai in Chrome | extension, model from the page | tested |
| chatgpt.com in Chrome | extension, model from the page when shown (GPT-5 otherwise) | tested |
| Google AI Overviews and AI Mode in Chrome | extension, one prompt per AI answer, follow-ups included | tested (English and Italian Google) |
| gemini.google.com in Chrome | extension | built, not confirmed |
| Other AI chat sites in Chrome: Qwen, DeepSeek, Le Chat, Perplexity, Grok, Kimi, Copilot, Z.ai, HuggingChat, Poe | extension's general meter | built, checked only on a simulated chat |
| Claude desktop app's chat, Cowork, desktop chat apps, Firefox, Safari, local models | — | not yet |

## Install

Needs macOS 14+ and the Swift toolchain (Xcode Command Line Tools are enough).

```bash
./build.sh
```

```bash
open build/Tracky.app
```

`build.sh` also runs the self-tests. Two more flags help with checking:

```bash
build/Tracky.app/Contents/MacOS/Tracky --dump
```

```bash
build/Tracky.app/Contents/MacOS/Tracky --preview docs/preview.png
```

`--dump` prints what Tracky read from the last 24 hours. `--preview` renders every heat level, awake and asleep, to a PNG, adding a few sample browser events so the legend fills up.

### Browser tracking (optional, Chrome)

Click the globe on Tracky's card, or *Browser tracking* in the menu, and follow the two steps:

1. **Connect Chrome:** registers Tracky as Chrome's [native messaging](https://developer.chrome.com/docs/extensions/develop/concepts/native-messaging) host, so the extension can reach it.
2. **Add the extension:** opens Chrome's extensions page and the extension folder bundled in Tracky. Turn on **Developer mode**, click **Load unpacked**, and pick that folder.

The dot turns green once the extension checks in. *Turn off* in the same box removes the link.

## How it sees your AI use

**Local tools.** Tracky reads Claude Code's own logs (`~/.claude/projects/*/*.jsonl`): for each reply, the model, output and thinking tokens, and effort. These counts are exact.

**The browser (optional).** When an AI reply finishes, the extension sends Tracky the site, the model and an approximate token count, never the text. Tracky stores each event as one line in `~/Library/Application Support/Tracky/browser.jsonl`. There are two ways it notices replies:

- **Dedicated watchers** for claude.ai, ChatGPT, Gemini and Google search. They read each site's page structure, which also gives the model name. Sites can change that structure without notice.
- **A general meter** for the other listed sites. It notices that the page is streaming a reply (a request whose answer arrives in pieces), then measures how much visible text the page gained. It never reads what is sent or streamed, only the model name when the request carries one. Adding a site is one line in `extension/manifest.json`.

Browser token counts are estimates (about 4 characters per token). A reply counts only once Tracky has seen it stream in, so an old chat you open is never counted. If a site stops counting, open its DevTools console: every counted reply logs a `[tracky]` line.

## How the water is estimated

Tracky is a Swift port of the [EcoLogits](https://ecologits.ai) LLM inference method (v0.11.3), checked by `--selftest` against the Python library's own output.

1. **Energy per request** comes from the number of output tokens and the model's active parameters, fitted on the [ML.ENERGY leaderboard](https://ml.energy/leaderboard) (GPU), plus the server's share during generation, scaled by the data center's PUE.
2. **Water** follows [Li et al. 2025, *Making AI Less "Thirsty"*](https://arxiv.org/abs/2304.03271): on-site cooling water (the data center's WUE) plus off-site water used to generate its electricity ([WRI method](https://www.wri.org/research/guidance-calculating-water-use-embedded-purchased-electricity)).
   `water = IT energy × (WUE on-site + PUE × WUE off-site)`
3. **Model sizes** come from EcoLogits' `models.json`, bundled unchanged in `Resources/`. Closed models (Claude, GPT) don't publish their sizes, so EcoLogits estimates a range. Tracky computes the min–max range and shows its midpoint, marked `≈`.

Two cases go beyond EcoLogits:

- **Google** (Gemini and AI Overviews): Tracky uses Google's own measurement, [0.26 mL of water per median Gemini text prompt](https://services.google.com/fh/files/misc/measuring_the_environmental_impact_of_delivering_ai_at_google_scale.pdf).
- **Models EcoLogits doesn't know** (Qwen, DeepSeek, Kimi, Grok and others): the same formula with an assumed size range of 200–1,000B total and 20–100B active parameters, the widest data-center figures EcoLogits uses, and world-average electricity water. Treat these numbers as an order of magnitude.

For scale, by EcoLogits, 1,000 output tokens from Opus 5.5 cost about 10–24 mL, and from Haiku 5.5 about 0.2–0.6 mL.

### Known limits

- **Only output tokens count.** Like EcoLogits, Tracky ignores input. In agent sessions most tokens are re-reads of cached context, so long sessions are underestimated.
- Training and hardware manufacturing are not included; EcoLogits doesn't model water for those.

## Credits

- [EcoLogits](https://github.com/genai-impact/ecologits) by GenAI Impact: method and `Resources/models.json` (MPL-2.0).
- [claude-mascot](https://github.com/No-one9/claude-mascot) (MIT): inspiration for the card, the pixel mascot and the no-Xcode build.
- Related: [Drippy](https://github.com/trnprnc/Drippy), a menu-bar meter of the energy and water behind Claude Code.
