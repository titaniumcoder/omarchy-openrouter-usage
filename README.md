# OpenRouter Usage Plus — Omarchy bar widget

Live OpenRouter credits and spend in the Omarchy (Quattro / 4.x) bar.

![OpenRouter Usage Plus panel](assets/screenshot.png)

- **Bar** — OpenRouter mark plus remaining prepaid credit
- **Header** — remaining balance on the right of OpenRouter / prepaid
- **Shortcuts** — Add Credits, Full Activity, Manage Keys, Browse Models
- **Spend by day** — last 7 days of rated cost
- **Details** — sticky expand: spend, requests, tokens, cache hit, top models, top apps, top keys

Derived from [ssobhani/omarchy-openrouter-usage](https://github.com/sepehr500/omarchy-openrouter-usage) (MIT). This plugin does **not** replace the stock `omarchy.agents` widget.

## Requirements

- Omarchy 4.x (Quattro)
- An OpenRouter API key
- Optional: [management key](https://openrouter.ai/settings/management-keys) for Top Apps and Top Keys
- Optional: pi/omp OpenRouter sessions for local spend-by-day when analytics is unavailable

## Install

```bash
omarchy plugin add https://github.com/calmasacow/omarchy-openrouter-usage-plus.git --enable
```

Then provide your API key. Either export `OPENROUTER_API_KEY`, or (recommended, works for the widget refresh timer):

```bash
mkdir -p ~/.config/omarchy/agents
cat > ~/.config/omarchy/agents/openrouter.json <<EOF
{"apiKey": "sk-or-v1-..."}
EOF
chmod 600 ~/.config/omarchy/agents/openrouter.json
```

The widget appears once the first scan finds a usable account or local usage.

## Optional: Details from the Activity API

Top Apps and Top Keys come from OpenRouter Analytics. That API rejects inference keys (403). Create a read-only [management key](https://openrouter.ai/settings/management-keys) and add it:

```json
{"apiKey": "sk-or-v1-...", "managementKey": "sk-or-v1-..."}
```

Or export `OPENROUTER_MANAGEMENT_KEY`. Without it, Details still shows cards from local pi/omp sessions when those exist; ranked lists stay hidden.

`d` toggles Details. Expand/collapse is remembered in bar settings.

## Optional: budget gauge

OpenRouter only reports lifetime purchases and usage. For a drain meter, set `fundedAmount` to your current top-up:

```json
{"apiKey": "sk-or-v1-...", "fundedAmount": 1000}
```

## Settings

Right-click the bar mark to refresh.

| Setting | Default | Meaning |
|---|---|---|
| `refreshIntervalSec` | 300 | How often the collector re-probes the account |
| `detailsExpanded` | false | Keep Details expanded across panel closes |

## Remove

```bash
omarchy plugin remove calmasacow.openrouter-usage-plus
```

Optionally delete `~/.config/omarchy/agents/openrouter.json` and `~/.cache/omarchy/agent-usage/openrouter-*.json`. The plugin does not rewrite other config.

## Credits

- Original widget: sepehr500 / ssobhani
- OpenRouter "OR" glyph from OpenRouter brand assets (openrouter.ai/brand/v2). OpenRouter is a trademark of its owner; this project is not affiliated.

## License

MIT
