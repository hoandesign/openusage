# Muse

Tracks local Muse CLI usage from the session logs Muse writes to `~/.local/share/muse`.

## What it tracks

| Metric | Meaning |
|---|---|
| Today / Yesterday / Last 30 Days | Tokens (and estimated cost) computed locally from Muse session logs |
| Usage Trend | 30-day token chart from the same local history |

Muse is local-only: there is no remote quota API yet. OpenUsage reads the Muse CLI session logs this Mac already writes under `~/.local/share/muse/sessions`, so the spend tiles reflect **Muse coding-agent usage on this Mac only** — not other Meta API apps or keys you created on [dev.meta.ai](https://dev.meta.ai/).

## Where credentials come from

- `META_API_KEY` environment variable (exported in your shell profile), or
- `~/.config/muse/auth.json` (the `providers.meta.access_token` written by `muse login`), or
- the presence of `~/.local/share/muse/sessions` itself (history from any prior Muse run).

No extra login is required beyond what Muse already uses. If none of those exist, the provider stays off and `hasLocalCredentials()` returns false so first-run detection (see [provider enablement](../provider-enablement.md)) does not enable it.

`MUSE_AUTH_PATH` and `XDG_CONFIG_HOME` / `XDG_DATA_HOME` overrides are honored, matching the Muse launcher's own resolution.

## Quick links

The Muse card's expander includes:

- **Usage** — [dev.meta.ai/usage](https://dev.meta.ai/usage). Opens Meta's account/project console (all API usage for that project, not just Muse CLI). When OpenUsage knows your Meta `project_id` and `team_id`, the link adds the same inclusive last-30-days window as the spend tiles. Without both ids the link stays bare — Meta's SPA otherwise injects ids and rewrites away the date window. The spend tiles above stay Muse-CLI-only.
- **Dashboard** — [dev.meta.ai](https://dev.meta.ai/)

## The spend tiles

Today / Yesterday / Last 30 Days are computed **locally** from qualified Muse CLI `session.jsonl` files. Each `model_completed` event for a `muse-spark*` model contributes `input_tokens + output_tokens + reasoning_tokens` (cached input is a subset of input, not added again) bucketed by local calendar day. Sessions must carry Muse CLI metadata (`provider_id: meta` with a Muse build stamp); subagent logs count when their parent session qualifies. Other Meta API clients on dev.meta.ai do not write these logs, so their usage is excluded automatically. Cost is estimated via the shared [model pricing](../pricing.md) using Meta's published tiers: **Standard** (`muse-spark-1.1` / `1.2` / `1.3` at $1.25 / $0.15 / $4.25 per 1M) and **Contributor** (`muse-spark-*-contributor`, including `1.2` and `1.3`, at $0.10 / $0.002 / $0.20 per 1M). Unpriced models are excluded from the totals and surface only as a warning triangle, matching other spend providers. The same daily series feeds the Usage Trend chart.

No log data leaves your Mac. A period with no recorded usage reads "No data" rather than "$0.00 · 0 tokens", matching every other spend-tracking provider.

## Troubleshooting

- **Muse shows "Not detected"** — run `muse login` or set `META_API_KEY`, or run any Muse session so `~/.local/share/muse/sessions` exists.
- **Tiles show "No data" but Muse has run** — check that sessions exist under `~/.local/share/muse/sessions` and that they contain `model_completed` lines with usage (older builds may not). Run a fresh Muse session and refresh.
- **Cost shows warning triangle** — the model slug has no pricing entry yet. Those rows are excluded from token/cost totals until pricing is added.

## Under the hood

No network calls. The scanner enumerates `session.jsonl` files under the sessions root (`$XDG_DATA_HOME/muse/sessions` or `~/.local/share/muse/sessions`) via `JSONLScanning`, parses each `model_completed` event's `recorded_at` (microseconds since epoch), `usage`, and `model`, and accumulates via `DailyUsageAccumulator`. Results flow through `SpendTileMapper` exactly like Claude/Codex/Grok's local spend tiles.
