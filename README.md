# Tracky

A small pixel water drop that lives on your Mac and shows how much water your Claude use costs, while you use it.

![Tracky at each heat level, awake in light mode and asleep in dark mode](docs/preview.png)

- **On the desktop:** a card you can drag anywhere. Tracky sleeps when Claude is idle and paces and hops while it works.
- **It heats up as you use more water.** A bar fills toward the next container, and each container you pass makes Tracky hotter:

  | Container | Liters | Tracky |
  |---|---|---|
  | cup | 0.25 | happy |
  | bottle | 1.5 | blushing |
  | toilet flush | 6 ([US limit, 1.6 gal](https://www.epa.gov/watersense/residential-toilets)) | a drop of sweat |
  | bucket | 10 | sweating, flushed, panting |
  | shower | 60 ([average US shower, 15.8 gal](https://home-water-works.org/indoor-use/showers)) | steaming |
  | bathtub | 150 | overheated, red |

- **Tips in a speech bubble:** every 24 seconds Tracky says one, such as *Try Haiku: ~42× less water* or *Try lower effort: 45% is thinking*.
- **Menu bar:** the drop and the total. Click it for the water per model, a tip, the period (last 1, 5 or 24 hours), switches to hide the card and to open Tracky at login (on by default), and *How is this estimated?*, which opens the EcoLogits method Tracky implements.

Everything stays on your Mac. Tracky reads only which model ran, when, and how many tokens it produced. It never reads prompts or replies, needs no permissions and makes no network calls.

## Run it

Needs macOS 14+ and the Swift toolchain (Xcode Command Line Tools are enough).

```bash
./build.sh
```

```bash
open build/Tracky.app
```

`build.sh` also runs the self-test. Two more flags help with checking:

```bash
build/Tracky.app/Contents/MacOS/Tracky --dump
```

```bash
build/Tracky.app/Contents/MacOS/Tracky --preview docs/preview.png
```

`--dump` prints what Tracky read from the last 24 hours. `--preview` renders every heat level, awake and asleep, to a PNG.

## What it tracks

Claude Code, in the terminal and in the Claude desktop app's Code tab. It reads `~/.claude/projects/*/*.jsonl`, and for each reply takes the model, output and thinking tokens, and effort.

Not tracked yet: Claude's chat (web and desktop), other AI tools, browser AI such as Google's AI Overviews, and local models.

## How the water is estimated

Tracky is a Swift port of the [EcoLogits](https://ecologits.ai) LLM inference method (v0.11.3), checked by `--selftest` against the Python library's own output.

1. **Energy per request** comes from the number of output tokens and the model's active parameters, fitted on the [ML.ENERGY leaderboard](https://ml.energy/leaderboard) (GPU), plus the server's share during generation, scaled by the data center's PUE.
2. **Water** follows [Li et al. 2025, *Making AI Less "Thirsty"*](https://arxiv.org/abs/2304.03271): on-site cooling water (the data center's WUE) plus off-site water used to generate its electricity ([WRI method](https://www.wri.org/research/guidance-calculating-water-use-embedded-purchased-electricity)).
   `water = IT energy × (WUE on-site + PUE × WUE off-site)`
3. **Model sizes** come from EcoLogits' `models.json`, bundled unchanged in `Resources/`. Anthropic doesn't publish Claude's sizes, so EcoLogits estimates a range. Tracky computes the min–max range and shows its midpoint, marked `≈`.

For scale, Google measured [0.26 mL of water per median Gemini text prompt](https://services.google.com/fh/files/misc/measuring_the_environmental_impact_of_delivering_ai_at_google_scale.pdf). By EcoLogits, 1,000 output tokens from Opus 5.5 cost about 10–24 mL, and from Haiku 5.5 about 0.2–0.6 mL.

### Known limits

- **Only output tokens count.** Like EcoLogits, Tracky ignores input. In agent sessions most tokens are re-reads of cached context, so long sessions are underestimated.
- Training and hardware manufacturing are not included; EcoLogits doesn't model water for those.

## Credits

- [EcoLogits](https://github.com/genai-impact/ecologits) by GenAI Impact: method and `Resources/models.json` (MPL-2.0).
- [claude-mascot](https://github.com/No-one9/claude-mascot) (MIT): inspiration for the card, the pixel mascot and the no-Xcode build.
- Related: [Drippy](https://github.com/trnprnc/Drippy), a menu-bar meter of the energy and water behind Claude Code.
