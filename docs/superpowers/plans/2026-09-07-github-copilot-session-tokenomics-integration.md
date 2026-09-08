# GitHub Copilot Session Tokenomics Integration — Research and Proposal

**Research date:** 2026-09-07

**Scope:** research and implementation planning only. This document does not authorize
reading user content, sending telemetry off-device, changing Copilot configuration, or
modifying application code.

**Evidence convention:** **Verified** statements are supported by the first-party URLs
linked inline or by the explicitly labelled local, schema-only observation. **Proposal**
and **Unknown** sections are design recommendations or questions that require a
controlled experiment; they are not claims about a stable GitHub contract.

> **Implementation note (2026-09-07):** The approved first PR implements local,
> read-only monitoring through an allowlisted SQLite projection and displays
> token-rate-derived **estimated AI credits** for known models. It does not claim
> account billing, send a keep-alive prompt, or read any session content. The estimate
> is based on GitHub's published rate table and remains unavailable for unknown models
> or incompatible schema; its relationship to actual profile billing remains
> intentionally unclaimed.

## Decision summary

**Revised proposal:** add a read-only local GitHub Copilot session-store provider as
Tokenomics' first Copilot integration. It can offer per-session and per-turn model,
token-bucket, and latency observability without requiring a GitHub credential.

**Direct local proof (2026-09-07):** a metadata-only, read-only query of the active
Copilot app agent session confirmed a matching row in `sessions`, `host_type = github`,
**144** `assistant_usage_events`, and a matching local
`~/.copilot/session-state/<session-id>` directory. Across the live store's **6,748**
usage events, `model`, `input_tokens`, `output_tokens`, `cache_read_tokens`, and
`cache_write_tokens` were non-NULL for all **6,748** rows; `reasoning_tokens` was
non-NULL for **6,711** rows. This establishes the feasibility of reliable *local
Copilot session telemetry* for the current app local-session configuration. It does
not make the undocumented schema or source-attribution fields a stable contract.

GitHub documents that Copilot CLI stores full session state locally and maintains a
local SQLite session store, but does **not** publish the SQLite schema as a stable
integration contract. The installed CLI in this environment contains an
`assistant_usage_events` table with the exact per-event columns needed for a
best-effort provider. Therefore, detect capabilities at runtime, retain unknown/raw
fields only in memory, and degrade visibly rather than treating the schema as
guaranteed.

GitHub's Copilot usage-metrics REST API should be an optional, organization/enterprise
daily-reconciliation source only. It has no documented personal endpoint and cannot
provide the local provider's per-session identity, per-turn model, cache-token,
reasoning-token, or latency data.

## Repository fit and extension points

### Verified repository facts

The existing app is a macOS menu-bar session observer. It already reads local agent
artifacts for Claude Code and Codex and describes Codex tracking as observe-only:
`README.md:12-24`.

The common `Session` model already contains the natural fields for a Copilot usage
provider: agent discriminator, current context, cached input, output, reasoning
output, model, effort, version, and optional cost:
`Sources/Tokenomics/Models/Session.swift:80-145`.

`CodexSessionWatcher` is the closest structural precedent. It is explicitly read-only,
performs bounded discovery, tolerates malformed/partial JSONL rows, extracts
model/version/token metadata, and uses a shared FSEvents watcher:
`Sources/Tokenomics/Services/CodexSessionWatcher.swift:3-34`,
`Sources/Tokenomics/Services/CodexSessionWatcher.swift:45-117`.

`SessionListViewModel` owns the provider watchers, starts their change watches, merges
their results in `rescan()`, and applies shared presentation work after scanning:
`Sources/Tokenomics/ViewModels/SessionListViewModel.swift:24-38`,
`Sources/Tokenomics/ViewModels/SessionListViewModel.swift:70-89`, and
`Sources/Tokenomics/ViewModels/SessionListViewModel.swift:209-230`.

The existing optional `UsageService` has the desired availability behavior: it reports
a nonfatal warning instead of fabricating a cost when its external source is missing:
`Sources/Tokenomics/Services/UsageService.swift:3-34`.

### Proposal: minimal integration shape

1. Add a `CopilotSessionWatcher` that has a read-only SQLite adapter and watches the
   Copilot SQLite database and WAL files with the existing `FSEventsWatcher`.
2. Add `.githubCopilotCLI` to `AgentKind`, rather than labelling Copilot events as
   Codex or Claude.
3. Prefer a small internal `CopilotUsageEvent` record and aggregate it into `Session`
   only at the UI boundary. This prevents a session that switches models from losing
   pricing and latency fidelity.
4. Add a `TelemetrySource` and `TelemetryConfidence` to make local observed events,
   GitHub daily aggregates, and estimates distinguishable.
5. Do not add a cache-expiry countdown or automatic keep-alive behavior for Copilot.
   The sources reviewed publish separate cache price buckets, but do not supply a
   documented local TTL signal comparable to the existing Claude Code data.
6. Do not reuse `UsageService`'s third-party `ccusage` dependency for Copilot. Query
   the local database directly and leave estimated pricing behind an explicit,
   versioned GitHub price catalog.

## Copilot products in scope

### Verified

| Product | What GitHub documents | Tokenomics relevance |
| --- | --- | --- |
| **Copilot CLI** | A terminal AI agent with interactive and programmatic interfaces, local and cloud sandbox options, automatic context management, and a `/context` command. [About Copilot CLI](https://docs.github.com/en/copilot/concepts/agents/copilot-cli/about-copilot-cli) | Primary local provider. CLI session state and a structured SQLite session store are documented locally. |
| **GitHub Copilot app** | A separate Copilot surface with a documented daily aggregate `totals_by_copilot_app` metric. [Copilot app metric fields](https://docs.github.com/en/copilot/reference/copilot-usage-metrics/copilot-usage-metrics#copilot-app-metrics-fields) | Aggregate-only unless GitHub later publishes a supported local/session API. |
| **Copilot cloud agent** | A GitHub-hosted autonomous agent with a GitHub Actions-powered ephemeral development environment that can research, plan, change code, test, and open a PR. [About Copilot cloud agent](https://docs.github.com/en/copilot/concepts/agents/cloud-agent/about-cloud-agent) | Optional enterprise reconciliation/PR-outcome surface; no documented local per-turn stream. |
| **IDE Copilot Chat and agent mode** | IDE agent mode performs local autonomous edits and is distinct from cloud agent; organization/enterprise metrics include IDE, feature, language, and chat-model aggregates. [Cloud-agent versus IDE agent mode](https://docs.github.com/en/copilot/concepts/agents/cloud-agent/about-cloud-agent#copilot-cloud-agent-versus-agent-mode) | Not a phase-one local provider: documented data is daily aggregate rather than local session telemetry. |
| **Third-party coding agents** | GitHub supports Anthropic Claude and OpenAI Codex as GitHub coding agents, currently in public preview, and exposes server-side aggregate job metrics for recognized agent apps. [About third-party coding agents](https://docs.github.com/en/copilot/concepts/agents/about-third-party-coding-agents) | Keep source/type normalization extensible; do not conflate with Copilot CLI. |

### Unknown

The reviewed public GitHub material does not document a stable local event store or a
third-party API that returns per-session/per-turn telemetry for GitHub Copilot app,
Copilot cloud agent, or IDE chat. Absence from documentation is not proof that an
internal service does not exist; it means Tokenomics must not depend on one.

## Data-source inventory

### A. Copilot CLI local session artifacts

#### Verified

Every Copilot CLI session is persisted locally. GitHub says its session data includes
prompts, responses, tools used, and modified-file details; it is stored under
`~/.copilot/session-state/`, while a SQLite session store holds a structured subset for
cross-session queries and `/chronicle`.
[About CLI session data](https://docs.github.com/en/copilot/concepts/agents/copilot-cli/chronicle)

GitHub's directory reference describes:

| Path | Documented purpose | Integration decision |
| --- | --- | --- |
| `~/.copilot/session-state/` | Per-session history and workspace artifacts; each session directory has `events.jsonl`. | Do not parse by default: its full content is sensitive and its event schema is not published as a stable contract. |
| `~/.copilot/session-store.db` | CLI-managed SQLite database for cross-session data such as checkpoint indexing and search. | Preferred local telemetry source, opened read-only. |
| `~/.copilot/logs/process-<timestamp>-<pid>.log` | Per-session diagnostic logs. | Not a metrics API; do not scrape it. |
| `~/.copilot/config.json` | Internal state including authentication and plugin metadata. | Never read. |
| `~/.copilot/mcp-oauth-config/`, `~/.copilot/mcp-secrets/` | OAuth/secret fallback state. | Explicitly prohibit access. |

Source: [GitHub Copilot CLI configuration directory](https://docs.github.com/en/copilot/reference/copilot-cli-reference/cli-config-dir-reference#directory-overview).

`COPILOT_HOME` replaces the complete default configuration/session root. The cache
directory is separate and can be configured with `COPILOT_CACHE_HOME`.
[Changing the CLI configuration location](https://docs.github.com/en/copilot/reference/copilot-cli-reference/cli-config-dir-reference#changing-the-location-of-the-configuration-directory)

CLI session data syncs to the user's GitHub account by default. A user can set
`"remoteExport": false` to keep it local. Business/Enterprise session sync additionally
depends on the administrator's “Store local sessions in the Cloud” policy, but an
administrator does not receive default access to a user's sessions merely by enabling
the policy.
[Session syncing and privacy](https://docs.github.com/en/copilot/concepts/agents/copilot-cli/chronicle#session-syncing)

#### Local observation — exact installed schema, not a public contract

On **2026-09-07**, this environment had GitHub Copilot CLI `1.0.83-5` installed, with
an available update to `1.0.84-1`. A schema-only inspection of
`~/.copilot/session-store.db` (no prompts, responses, tool output, or row data read)
found this table:

```text
assistant_usage_events(
  id INTEGER PRIMARY KEY,
  session_id TEXT NOT NULL,
  turn_index INTEGER,
  agent_id TEXT,
  parent_tool_call_id TEXT,
  model TEXT NOT NULL,
  input_tokens INTEGER,
  output_tokens INTEGER,
  cache_read_tokens INTEGER,
  cache_write_tokens INTEGER,
  reasoning_tokens INTEGER,
  total_nano_aiu INTEGER,
  request_multiplier REAL,
  duration_ms INTEGER,
  time_to_first_token_ms INTEGER,
  output_ttft_ms REAL,
  inter_token_latency_ms INTEGER,
  initiator TEXT,
  api_endpoint TEXT,
  reasoning_effort TEXT,
  finish_reason TEXT,
  content_filter_triggered INTEGER,
  token_details_json TEXT,
  created_at TEXT
)
```

The same database contains:

```text
sessions(id, cwd, repository, host_type, branch, summary, created_at, updated_at)
turns(session_id, turn_index, user_message, assistant_response, timestamp)
checkpoints(session_id, checkpoint_number, title, overview, ...)
session_files(session_id, file_path, tool_name, turn_index, first_seen_at)
session_refs(session_id, ref_type, ref_value, turn_index, created_at)
forge_trajectory_events(session_id, tool_call_id, turn_index, event_type,
                        command, output, exit_code, ...)
```

This proves that the installed version records local per-event model, input/output,
cache-read/cache-write, reasoning, latency, and request-multiplier-shaped values. It
does **not** establish semantic guarantees for every column.

#### Proposal: safe local query boundary

Use an allowlisted projection of `assistant_usage_events` and `sessions` only:

```sql
SELECT
  e.id, e.session_id, e.turn_index, e.agent_id, e.parent_tool_call_id,
  e.model, e.input_tokens, e.output_tokens, e.cache_read_tokens,
  e.cache_write_tokens, e.reasoning_tokens, e.total_nano_aiu,
  e.request_multiplier, e.duration_ms, e.time_to_first_token_ms,
  e.output_ttft_ms, e.inter_token_latency_ms, e.initiator,
  e.api_endpoint, e.reasoning_effort, e.finish_reason,
  e.content_filter_triggered, e.token_details_json, e.created_at,
  s.cwd, s.repository, s.host_type, s.branch, s.created_at, s.updated_at
FROM assistant_usage_events AS e
LEFT JOIN sessions AS s ON s.id = e.session_id;
```

Normal collection must **not** select:

- `turns.user_message` or `turns.assistant_response`;
- `forge_trajectory_events.command` or `.output`;
- full `events.jsonl`;
- secrets, auth configuration, or logs.

`token_details_json` is potentially useful for a future compatibility layer, but its
contents and stability are unknown. Store it only as an in-memory raw diagnostic value
behind a separate opt-in, or omit it entirely in initial releases.

#### Unknowns requiring experiment

- Whether `input_tokens` includes cached input and/or cache-write quantities, versus
  being an uncached base bucket.
- Whether one `assistant_usage_events` row maps one model request, a streamed response,
  a tool loop, a retry, an agent subtask, or another unit.
- The precise meanings and units of `total_nano_aiu`, `request_multiplier`,
  `output_ttft_ms`, and `token_details_json`.
- Whether `turn_index` is unique for a session when subagents or continuations exist.

Until verified, retain raw fields separately and avoid arithmetic that would double
count cache tokens.

### B. GitHub Copilot usage-metrics REST API and NDJSON reports

#### Verified

GitHub exposes Copilot usage metrics at organization and enterprise scope. The feature
must be enabled by enterprise policy and API calls return time-limited signed download
URLs for reports. Enterprise daily reports are available beginning **2025-10-10**, with
up to one year of historical access.
[REST API endpoints for Copilot usage metrics](https://docs.github.com/en/rest/copilot/copilot-usage-metrics)

Examples of documented endpoints:

```text
GET /orgs/{org}/copilot/metrics/reports/users-1-day
GET /orgs/{org}/copilot/metrics/reports/users-28-day/latest
GET /orgs/{org}/copilot/metrics/reports/organization-1-day
GET /orgs/{org}/copilot/metrics/reports/repos-1-day

GET /enterprises/{enterprise}/copilot/metrics/reports/users-1-day
GET /enterprises/{enterprise}/copilot/metrics/reports/enterprise-1-day
GET /enterprises/{enterprise}/copilot/metrics/reports/repos-1-day
```

Organization access requires an organization owner or “View Organization Copilot
Metrics” permission and appropriate authorization; enterprise access requires
enterprise ownership/billing authority or “View Enterprise Copilot Metrics.” See the
[REST API permission details](https://docs.github.com/en/rest/copilot/copilot-usage-metrics).

The documented per-user daily report can include:

```json
{
  "day": "2025-10-01",
  "user_id": 1,
  "user_login": "login1",
  "ai_credits_used": 12.5,
  "used_cli": true,
  "used_copilot_app": true,
  "used_copilot_cloud_agent": false,
  "totals_by_cli": {
    "session_count": 2,
    "request_count": 2,
    "prompt_count": 2,
    "token_usage": {
      "avg_tokens_per_request": 4400.0,
      "output_tokens_sum": 5000,
      "prompt_tokens_sum": 3800
    },
    "last_known_cli_version": {
      "cli_version": "1.0.8",
      "sampled_at": "2025-10-01T00:01:43.000Z"
    }
  },
  "totals_by_copilot_app": {
    "session_count": 1,
    "request_count": 3,
    "prompt_count": 1,
    "token_usage": {
      "avg_tokens_per_request": 3200.0,
      "output_tokens_sum": 4200,
      "prompt_tokens_sum": 5400
    }
  }
}
```

This is a shortened version of GitHub's example schema:
[Example schema for Copilot usage metrics](https://docs.github.com/en/copilot/reference/copilot-usage-metrics/example-schema#user-level-schema-example).

GitHub defines:

- `totals_by_cli.session_count`: distinct CLI sessions initiated that day;
- `totals_by_cli.request_count`: all CLI requests, including automated agentic
  follow-up calls;
- `totals_by_cli.prompt_count`: user prompts/commands/queries;
- `prompt_tokens_sum` and `output_tokens_sum`: daily total prompt and output tokens;
- `avg_tokens_per_request`: `(prompt + output) / request_count`;
- `totals_by_copilot_app` has corresponding daily app session/request/prompt/token
  totals.

The report does not include a CLI cache-token breakdown or CLI model breakdown.
[Metric field reference](https://docs.github.com/en/copilot/reference/copilot-usage-metrics/copilot-usage-metrics#copilot-cli-metrics-fields)

`ai_credits_used` in per-user reports is an aggregate reporting-period quantity and is
not broken down by model, feature, or surface.
[Per-user report fields](https://docs.github.com/en/copilot/reference/copilot-usage-metrics/copilot-usage-metrics#per-user-report-fields)

Repository reports provide pull-request lifecycle data, including Copilot-cloud-agent
and Copilot-code-review PR activity, not per-session token data.
[Repository report fields](https://docs.github.com/en/copilot/reference/copilot-usage-metrics/copilot-usage-metrics#repository-level-fields-api-only)

#### Proposal

Offer an **opt-in import/reconciliation** feature only when the user has independently
obtained an authorized report or deliberately provides a credential. Parse the daily
NDJSON report into a source labelled `githubMetricsDaily`, preserve its report day and
scope, and display it separately from local session totals.

Do not merge a report row into local sessions. Its scope can include other devices and
surfaces; its `request_count` includes automatic calls; and it lacks event IDs and cache
details. A reconciliation screen can instead compare local CLI totals against the
authorized daily `totals_by_cli` total and explain expected scope/time differences.

#### Unknown / unavailable to a third-party project

The sources reviewed document no personal-user metrics endpoint, public REST or
GraphQL endpoint for a user's synced session transcript, public per-session/per-turn
cloud-agent telemetry endpoint, or exact token-level invoice endpoint. Do not scrape
GitHub web pages, terminal UI, or non-public network traffic to fill these gaps.

### C. CLI interactive insights and diagnostic logs

#### Verified

`/chronicle` can generate session-history standups, tips, cost tips, search results,
and reindex the local session store. It is a user-facing analysis command, not a
documented machine-readable telemetry API.
[Using Copilot CLI session data](https://docs.github.com/en/copilot/how-tos/copilot-cli/use-copilot-cli/chronicle)

GitHub documents `/context` as a detailed context-usage breakdown and automatic
compaction at 95% of the model's token limit.
[CLI automatic context management](https://docs.github.com/en/copilot/concepts/agents/copilot-cli/about-copilot-cli#automatic-context-management)

#### Proposal

Treat these as manual diagnostics users may compare against Tokenomics; do not automate
or scrape their terminal output. The SQLite collector is more structured and has a
smaller privacy footprint when restricted to numeric/metadata columns.

## Billing, pricing, and what “cost” may mean

### Verified: current usage-based billing

GitHub's current usage-based billing measures Copilot interactions in **GitHub AI
Credits**. An interaction consumes model-specific input, output, and cached-token
quantities; the resulting value is converted at **1 AI credit = USD $0.01**.
[Usage-based billing for individuals](https://docs.github.com/en/copilot/concepts/billing/usage-based-billing-for-individuals)

Copilot Chat, CLI, cloud agent, Spaces, Spark, and third-party coding agents consume
AI credits. Code completions and next-edit suggestions are not billed in AI credits.
[Usage-based billing for organizations and enterprises](https://docs.github.com/en/copilot/concepts/billing/organizations-and-enterprises/usage-based-billing)

Current documented included allowances are:

| Plan | Included AI credits |
| --- | ---: |
| Copilot Pro | 1,500/month |
| Copilot Pro+ | 7,000/month |
| Copilot Max | 20,000/month |
| Copilot Business | 1,900/seat/month, pooled by billing entity |
| Copilot Enterprise | 3,900/seat/month, pooled by billing entity |

Sources: [individual allowance](https://docs.github.com/en/copilot/concepts/billing/usage-based-billing-for-individuals#github-ai-credits-allowance-by-plan) and
[organization/enterprise allowance](https://docs.github.com/en/copilot/concepts/billing/organizations-and-enterprises/usage-based-billing#how-do-ai-credits-work).

GitHub publishes token rates by model and bucket. For example, the current default-tier
table lists GPT-5.6 Terra at `$2.00` input, `$0.20` cached input, `$2.50` cache write,
and `$12.00` output per million tokens; it lists Claude Sonnet 5 at `$2.00`, `$0.20`,
`$2.50`, and `$10.00`, respectively. Long-context tiers may have a threshold and
different price. The catalog is explicitly subject to change.
[Models and pricing for GitHub Copilot](https://docs.github.com/en/copilot/reference/copilot-billing/models-and-pricing)

Copilot cloud agent also consumes GitHub Actions minutes, distinct from AI credits.
[Cloud-agent usage costs](https://docs.github.com/en/copilot/concepts/agents/cloud-agent/about-cloud-agent#copilot-cloud-agent-usage-costs)

### Verified: legacy premium requests

Premium-request multipliers are a **legacy** model for annual Pro/Pro+ subscribers who
remained on request-based billing after **2026-06-01**; GitHub says they do not apply
to new usage-based billing. Under this legacy system, CLI consumes one premium request
per prompt multiplied by the model rate. Cloud agent consumes one request per session
and one per real-time steering comment; autonomous tool calls are not separately
premium-request billed.
[Legacy request semantics](https://docs.github.com/en/copilot/reference/copilot-billing/request-based-billing-legacy/copilot-requests)

### Proposal: cost presentation

Present two distinct quantities:

1. **Estimated token cost / estimated AI credits** — calculated from local observed
   token buckets, a date-versioned GitHub rate catalog, and only confirmed
   input/cache semantics.
2. **Reported billing usage** — `ai_credits_used` from an authorized daily
   organization/enterprise report, available only at its aggregate scope.

Never call an estimate “billed cost” or “invoice total.” Included-credit pools, plan
allowances, Auto discounts, model routing, timing, organization attribution, cloud
Actions minutes, and additional-usage budgets prevent that conclusion.

For legacy users, display a separately labelled “legacy premium-request estimate” only
when the user explicitly confirms that billing status. Do not derive it from tokens.

## Model selection, policy, configuration, and caches

### Verified

Copilot CLI configuration precedence is:

1. built-in defaults;
2. Mobile Device Management settings;
3. user `~/.copilot/settings.json`;
4. repository `.github/copilot/settings.json`;
5. local `.github/copilot/settings.local.json`;
6. environment variables;
7. command-line flags.

[Configuration precedence](https://docs.github.com/en/copilot/reference/copilot-cli-reference/cli-config-dir-reference#configuration-file-settings)

Copilot CLI's authentication environment precedence is `COPILOT_GITHUB_TOKEN`, then
`GH_TOKEN`, then `GITHUB_TOKEN`. Fine-grained PATs may have the “Copilot Requests”
permission. These facts are relevant only to explicitly prohibit a Tokenomics provider
from inspecting or exporting them.
[CLI authentication options](https://docs.github.com/en/copilot/reference/copilot-cli-reference/cli-command-reference#copilot-login-options)

Enterprise and organization policy can limit features and models. Copilot CLI and
Copilot app have independent client policies.
[Copilot policies](https://docs.github.com/en/copilot/concepts/policies)

Auto model selection is available in Copilot Chat, Copilot CLI, cloud agent, and the
Copilot app. It considers task complexity, availability, plan, and policy; GitHub says
task-optimized routing occurs at natural cache boundaries to avoid extra cache-related
cost. Paid users get a documented 10% Auto model-cost discount.
[About Copilot auto model selection](https://docs.github.com/en/copilot/concepts/models/auto-model-selection)

Cloud-agent model and reasoning selection depends on the entrypoint. Where no picker is
available, Auto is used; higher reasoning may take longer and use more AI credits.
[Changing the cloud-agent model](https://docs.github.com/en/copilot/how-tos/use-copilot-agents/cloud-agent/changing-the-ai-model)

### Proposal

- Record `model` on every `CopilotUsageEvent`, preserving `modelRaw` and a
  date-versioned canonical price-catalog ID. Never infer it from a current UI setting.
- Record `reasoning_effort` as observed metadata, but do not infer a separate
  reasoning price unless GitHub documents one for the active catalog.
- Record an `autoSelected` state only if it is explicitly present in a safe observed
  field or user configuration. Do not apply the 10% discount merely because a model
  could have been selected by Auto.
- Store a pricing catalog version/effective date with every estimate.
- Make model-policy/configuration inspection opt-in and metadata-only; a local tracker
  generally does not need to parse `settings.json`.

### Unknown

GitHub pricing distinguishes fresh input, cached input, cache writes, and output, but
the public docs reviewed do not define whether local
`assistant_usage_events.input_tokens` includes cached or cache-write token values.
Consequently, the initial provider must surface raw buckets and leave cost unknown if
the compatibility rule is unverified.

## Proposed normalized model

```text
TelemetrySource = copilotLocalSessionStore | githubMetricsDaily
TelemetryConfidence = observed | documentedAggregate | estimated

CopilotUsageEvent
  source, confidence, sourceVersion, schemaFingerprint
  eventID, sessionID, turnIndex, agentID, parentToolCallID
  observedAt, modelRaw, modelCanonical, reasoningEffort
  inputTokens, cachedInputTokens, cacheWriteTokens
  outputTokens, reasoningTokens
  durationMs, timeToFirstTokenMs, outputTTFTMs, interTokenLatencyMs
  initiator, apiEndpoint, finishReason, contentFilterTriggered
  aiuRaw, requestMultiplierRaw
  estimatedUSD, estimatedAICredits
```

### Mapping rules (proposal)

| Local observed column | Normalized field | Handling |
| --- | --- | --- |
| `id` | `eventID` | Stable local deduplication key while available. |
| `session_id` | `sessionID` | Join key to `sessions.id`; use as a display/session aggregate key. |
| `turn_index` | `turnIndex` | Preserve nullable; do not assume it uniquely identifies an API call. |
| `model` | `modelRaw` | Required in observed schema; preserve verbatim and separately map to pricing ID. |
| `input_tokens` | `inputTokens` | Preserve raw semantics until cache accounting is experimentally verified. |
| `cache_read_tokens` | `cachedInputTokens` | Preserve raw; do not add/subtract from input automatically. |
| `cache_write_tokens` | `cacheWriteTokens` | Preserve separate from read. |
| `output_tokens` / `reasoning_tokens` | output/reasoning | Preserve separately; never assume reasoning is included/excluded from output without experiment. |
| latency columns | latency fields | Milliseconds as named; nullable values remain unavailable. |
| `total_nano_aiu`, `request_multiplier` | raw billing diagnostics | Do not label as credits/dollars without controlled validation. |
| `created_at` | `observedAt` | Preserve source timestamp and its source-timezone semantics. |

For aggregate GitHub NDJSON data, map a record to a separate `DailyUsageAggregate`, not
to `CopilotUsageEvent`: it has a date/scope and totals but no event/session identity.

## Privacy and security constraints

### Proposal: non-negotiable defaults

- **Local-only by default.** No telemetry upload, analytics endpoint, GitHub API call,
  or change to `remoteExport`.
- Require a clear user opt-in before accessing the Copilot root. Explain that session
  artifacts can contain prompts, responses, tools, filenames, commands, and outputs.
- Query only allowlisted non-content columns; never read `turns`, raw event JSONL,
  trajectory command/output, or logs in normal collection.
- Never inspect, log, render, cache, or transmit authentication/token files or
  environment variables.
- Open SQLite with a read-only connection and busy timeout. Never migrate, write,
  checkpoint WAL, vacuum, copy session data, or modify the CLI's files.
- Resolve `COPILOT_HOME` first; canonicalize the resulting path and reject unsafe
  symlink/path escape behavior before configuring the watcher.
- Do not put token counts, model names, working directories, or session IDs into
  notification payloads, persistent debug logs, analytics, or crash reports unless
  the user explicitly opts in.
- Turning the provider off stops watching and clears in-memory Copilot data.

These constraints are stronger than read-only access alone because the documented
session state is a complete work record.

## Reliability ladder

| Priority | Source | Fidelity | Fallback behavior |
| --- | --- | --- |
| A | Local `assistant_usage_events` | Per local event/turn: model, token buckets, latency, raw multiplier/AIU fields. | Preferred. Show CLI version/schema compatibility state. |
| B | Local `sessions` joined to usage events | Per-session metadata and model aggregates. | Keep session summary if turn mapping is missing. |
| C | Authorized organization/enterprise daily NDJSON | Daily CLI/app session/request/prompt/input/output totals; per-user AI credits. | Label as daily reconciliation only. |
| D | `/chronicle cost tips` and `/context` | User-facing diagnostic insights. | Manual comparison only; never scrape. |
| E | `session-state/events.jsonl` | Potential full fidelity but undocumented schema and highly sensitive content. | Disabled recovery experiment only, never normal collection. |
| F | No source | No estimate. | Surface provider unavailable with cause; never estimate from text length. |

## Experiments required before a cost claim

1. **Token-bucket semantics:** run a controlled prompt on each selected model and
   compare SQLite columns, `/context`, the model rate formula, and visible AI-credit
   changes where available. Establish whether `input_tokens` includes cached input or
   cache writes.
2. **Event cardinality:** verify row counts for normal response, tool loop, retry,
   streaming, subagent, Auto routing, manual compaction, and continuation.
3. **Raw billing fields:** establish the exact meaning/unit of `total_nano_aiu` and
   `request_multiplier` from controlled deltas before naming either in the UI.
4. **Schema drift:** compare `PRAGMA table_info`, `schema_version`, and provider output
   before/after a Copilot CLI upgrade. Current release changes are frequent:
   [official release notes](https://github.com/github/copilot-cli/releases).
5. **WAL/live writer behavior:** verify no `SQLITE_BUSY`, partial snapshots, or
   duplicate totals while a session is actively generating.
6. **Metrics reconciliation:** compare one controlled local CLI day with an authorized
   `totals_by_cli` report. Document expected deltas from other devices, report
   processing, and server-side automatic calls.
7. **Cloud-agent attribution:** test whether GitHub Actions/job data can be joined to
   an aggregate report without falsely representing it as per-token session data.
8. **Copilot-app telemetry:** defer until GitHub publishes a supported client-visible
   local/session interface.

## Phased implementation plan

### Phase 0 — compatibility and privacy spike

**Deliverables**

- A read-only SQLite adapter with a testable root resolver (`COPILOT_HOME`, then
  `~/.copilot`).
- Runtime schema capability detection using `PRAGMA table_info`.
- An explicit provider status model and no UI metrics yet.

**Acceptance criteria**

- Missing root, database, table, or required column results in a precise nonfatal
  warning.
- Tests prove no SQL query selects prompt, response, command, output, or secret data.
- Tests prove no filesystem mutation, WAL checkpoint, schema migration, or copy occurs.
- A user can disable the provider and release its file watches.

### Phase 1 — local Copilot CLI usage provider

**Deliverables**

- `CopilotSessionWatcher` and `CopilotUsageEvent`.
- `.githubCopilotCLI` agent kind plus source/confidence presentation.
- FSEvents refresh of DB/WAL and aggregation by session/model for the existing
  `SessionListViewModel`.

**Acceptance criteria**

- Fixture data maps every observed numeric/metadata field without integer overflow.
- A session with two models preserves both event groups before UI aggregation.
- `NULL` numeric values remain unavailable rather than becoming zero.
- Repeated scans are idempotent; WAL retry/backoff does not duplicate totals.
- A fixture with an unknown future model presents raw tokens and “cost unavailable.”
- Existing Claude Code and Codex tests remain unaffected.

### Phase 2 — estimates and model catalog

**Deliverables**

- Versioned GitHub pricing catalog with effective date, model aliases, token buckets,
  long-context thresholds, and source URL.
- A token-semantics compatibility gate, initially off until Phase 0 experiments pass.

**Acceptance criteria**

- Deterministic tests cover fresh input, cached input, cache write, output, long
  context, unknown model, unknown cache semantics, and a dated catalog change.
- Every calculated value is labelled “estimated AI credits” and “estimated USD.”
- No implementation describes an estimate as invoice/billed usage.

### Phase 3 — optional enterprise/organization aggregate import

**Deliverables**

- Explicit opt-in report import or user-provided authenticated fetch.
- NDJSON parser for GitHub's `totals_by_cli` and `totals_by_copilot_app` data.
- Daily reconciliation UI/card with report scope and timestamp.

**Acceptance criteria**

- Parser accepts GitHub's example report shape and rejects malformed/non-NDJSON data.
- Credential material is never persisted by Tokenomics.
- UI cannot display aggregate data as an individual session/turn or cache breakdown.
- Reconciliation clearly distinguishes local window/timezone from report-day scope.

### Phase 4 — documentation and product hardening

**Deliverables**

- Settings explanation, source badges, compatibility diagnostics, privacy statement,
  retention behavior, and source links.
- Upgrade/schema-drift playbook and manual verification checklist.

**Acceptance criteria**

- First-use consent explains what is and is not read.
- Disabling removes in-memory Copilot metrics and stops watches.
- App behaves normally on a machine without Copilot CLI.
- Release notes include source schema/version context and the date of the pricing
  catalog.

## Addendum — GitHub Copilot app versus Copilot CLI session storage (2026-09-07)

**Purpose:** This addendum re-evaluates the narrower claim that the GitHub Copilot app
is a wrapper over Copilot CLI, and whether its sessions can safely be collected from
the local CLI session store. It supersedes any implication elsewhere in this document
that a local CLI store automatically represents all Copilot app activity.

### Definitive conclusion

**Verified:** GitHub states that the GitHub Copilot app is **“built on GitHub Copilot
CLI.”** GitHub-owned app release notes additionally refer to app-managed “Copilot CLI
processes,” to sessions sharing a CLI process, and to the workspace UI displaying the
“actual Copilot CLI session ID.” This establishes that Copilot app *agent sessions* use
the CLI agent runtime and can expose a CLI session identity.

**Not verified / do not assume:** GitHub does not publish a contract saying that every
Copilot app agent session—or every app chat—is represented as a local
`~/.copilot/session-state/<id>` record or as a row in
`~/.copilot/session-store.db`. Nor does it publish the SQLite schema, a `host_type`
enumeration, a universal one-to-one app-ID-to-CLI-ID mapping, or a supported
app/CLI source discriminator in local telemetry.

**Direct local validation (2026-09-07):** a known active Copilot app **local agent
session** was queried through a metadata-only, read-only SQLite connection. It had a
`sessions` row, `host_type = github`, **144** `assistant_usage_events`, and a matching
`~/.copilot/session-state/<session-id>` directory. The session ID, content, paths,
timestamps, credentials, prompts, responses, tool input, and tool output were not
copied into this report or queried for this result. This is direct local proof that the
current app local-agent-session configuration is materialized in the CLI session store
and local session-state hierarchy.

The same metadata-only validation found **6,748** total `assistant_usage_events`.
`model`, `input_tokens`, `output_tokens`, `cache_read_tokens`, and
`cache_write_tokens` were present in **6,748 / 6,748** events; `reasoning_tokens` was
present in **6,711 / 6,748** events. This establishes high field coverage for the
numeric local telemetry required by Tokenomics, subject to the semantic/billing
caveats below.

**Revised recommendation:** implement a **local GitHub Copilot session-store
provider**, because reliable local session telemetry is now directly demonstrated and
is realistically comparable to Tokenomics' existing local providers. Its source must
be named `copilotLocalSessionStore`, and arbitrary session origin must remain
**unclassified**: `host_type` and `initiator` have no documented app/CLI semantics.
The provider can collect safe observed local event data, including the current app
local-agent-session shape, but must not publish app-specific totals until attribution
has a documented contract or a separately maintained, version-pinned compatibility
rule. Capability detection, read-only allowlisted queries, versioned fixtures,
schema-drift handling, and nonfatal degradation are required. It must make no
unsupported invoice, billing-credit, or token-bucket-arithmetic claim.

App chats and app cloud-sandbox sessions remain out of scope unless separately proven.

### 1. Architecture and relation to CLI

#### Verified

GitHub's app-session documentation says:

> “Because the GitHub Copilot app is built on GitHub Copilot CLI, you can use Copilot
> CLI session history features such as `/chronicle` to get insights from work you did
> in the app and in other Copilot CLI sessions.”

[Working with agent sessions in the GitHub Copilot app](https://docs.github.com/en/copilot/how-tos/github-copilot-app/agent-sessions#using-chronicle-with-app-sessions)

The public GitHub Copilot app changelog provides operational corroboration. It records
a Windows fix for lingering **“Copilot CLI processes”** after app exit and a fix for
sessions sharing a CLI process/resuming after process failure.
[GitHub Copilot app release notes — CLI processes](https://github.com/github/app/blob/main/changelog.md#L141),
[shared CLI process](https://github.com/github/app/blob/main/changelog.md#L185)

The GitHub-owned Copilot SDK documents the generic runtime design: it exposes “the
same engine behind Copilot CLI,” communicates with CLI server mode through JSON-RPC,
and manages the CLI process lifecycle. This supports the interpretation that the app
hosts/orchestrates the CLI runtime; it does **not** prove every app code path uses the
public SDK.
[GitHub Copilot SDK README](https://github.com/github/copilot-sdk/blob/main/README.md#architecture)

The public `github/app` repository describes itself as a download, issue, discussion,
and release-notes home; it does not contain the app implementation. Thus there is no
public source for a complete app-UI-to-CLI-server call graph.
[GitHub Copilot app repository README](https://github.com/github/app/blob/main/README.md#this-repository)

#### Exact interpretation

“Built on CLI” is a verified platform relationship, but “wrapper” is imprecise. The
app has its own product-level orchestration: every app agent session has an isolated
workspace; users choose local repository, worktree, or cloud sandbox execution; and
they choose session mode, model, and reasoning effort. It also has chats that do not
create a dedicated branch or worktree.
[Working with agent sessions in the GitHub Copilot app](https://docs.github.com/en/copilot/how-tos/github-copilot-app/agent-sessions#starting-a-session),
[Using chats in the GitHub Copilot app](https://docs.github.com/en/copilot/how-tos/github-copilot-app/agent-sessions#using-chats)

Therefore, the supported conclusion is **CLI-backed agent runtime with app-specific
host/workspace/UI behavior**, not a claim that the installed CLI executable alone
fully defines every app capability or persistence behavior.

### 2. Session identity and one-to-one correspondence

#### Verified

App release notes state that the workspace popover displays the **“actual Copilot CLI
session ID.”** This is direct evidence that an app workspace exposes a CLI session
identity.
[GitHub Copilot app release notes](https://github.com/github/app/blob/main/changelog.md#L615)

The CLI release notes also say that the `/app` command opens the **current session** in
the GitHub Copilot desktop app, rather than opening the app home with the wrong folder.
This is direct CLI-to-app handoff evidence.
[GitHub Copilot CLI release notes](https://github.com/github/copilot-cli/blob/main/changelog.md#L122)

GitHub's CLI session-data document says that each **CLI** session is persisted locally
in `~/.copilot/session-state/`, and that the CLI creates a local SQLite “session
store” containing a structured subset of that session data.
[About Copilot CLI session data](https://docs.github.com/en/copilot/concepts/agents/copilot-cli/chronicle#how-session-data-is-stored)

#### Unknown

The public sources reviewed do not specify:

- whether every app-created **agent session** gets exactly one distinct CLI session ID;
- whether an app session ID exists in addition to a CLI ID and how either is mapped;
- whether all app **chats** have a CLI session ID;
- whether a cloud-sandbox app session writes a record to the local machine's
  `~/.copilot` directory; or
- whether app session resumption is served from the local SQLite store, local
  session-state files, synced account data, another local app store, or a combination.

The app release-note identity statement establishes a CLI ID for the described
workspace feature; it is not a universal persistence/schema guarantee.

### 3. Session state, model selection, tools, and local persistence

#### Verified

The app lets users choose a session's workspace, mode, model, and reasoning effort;
Auto can select a model by task complexity. The app also supports local and
cloud-sandbox execution.
[Working with agent sessions in the GitHub Copilot app](https://docs.github.com/en/copilot/how-tos/github-copilot-app/agent-sessions#starting-a-session),
[Choosing a model](https://docs.github.com/en/copilot/how-tos/github-copilot-app/agent-sessions#choosing-a-model)

Copilot CLI session scope includes conversation state and tool activity, including its
working directory, permissions, approvals, and mode.
[Working with multiple Copilot CLI sessions](https://docs.github.com/en/copilot/how-tos/copilot-cli/use-copilot-cli/work-with-multiple-sessions)

The SDK exposes CLI first-party tools by default and supports the models available
through CLI, although host applications can govern tool calls and add agents, skills,
and tools.
[GitHub Copilot SDK README](https://github.com/github/copilot-sdk/blob/main/README.md#tools),
[GitHub Copilot SDK README](https://github.com/github/copilot-sdk/blob/main/README.md#models)

#### Unknown

No reviewed public source promises that every selected model, reasoning setting,
approval, tool catalog, custom agent, skill, or complete in-memory context transfers
unchanged between an app session and a terminal CLI session. The common engine makes
some shared behavior plausible, but it is not a reliable tokenomics attribution rule.

GitHub does document cross-product **synced** session history: CLI session syncing lets
the user query history from CLI, VS Code, JetBrains, the app, and GitHub.com, including
sessions from cloud agent, code review, VS Code, and the app. This proves account-level
history access, not that every such record is in the local CLI SQLite database.
[About Copilot CLI session data](https://docs.github.com/en/copilot/concepts/agents/copilot-cli/chronicle#session-syncing)

### 4. Safe local schema inspection: observed values and their limit

#### Initial aggregate observation — schema and metadata only

An earlier 2026-09-07 read-only inspection of this machine's
`~/.copilot/session-store.db` found `sessions.host_type` in the local `sessions` table.
No session text, summaries, filesystem paths, prompts, responses, commands, tool
outputs, session IDs, or timestamps were read.

```text
sessions(
  id TEXT PRIMARY KEY, cwd TEXT, repository TEXT, host_type TEXT,
  branch TEXT, summary TEXT, created_at TEXT, updated_at TEXT
)
```

The initial aggregate results were:

| Observed `host_type` | Session rows | Session rows with an `assistant_usage_events` row | Usage-event rows |
| --- | ---: | ---: | ---: |
| `github` | 47 | 47 | 6,596 |
| `NULL` | 9 | 9 | 128 |
| **Total** | **56** | **56** | **6,724** |

These are an earlier live-store sample, not the current global event total. A subsequent
targeted validation established the current **6,748**-event total and the active app
local-agent-session result described in the definitive conclusion. It did not repeat
the complete host-type distribution, so this document does not infer an updated
per-`host_type` event split.

No observed value was `app`, `copilot_app`, `cli`, or an otherwise documented
app/CLI discriminator. The database did not contain a `session_usage` table in this
installed version. It contains `sessions`, `assistant_usage_events`, `turns`,
`checkpoints`, `session_files`, `session_refs`, `forge_trajectory_events`, and search
index/support tables.

Aggregating the non-content `assistant_usage_events.initiator` metadata yielded only
runtime-role-like values—`user`, `agent`, `sub-agent`, `compaction`, and `NULL`—not an
app/CLI host label. These values describe no documented product-surface contract.

#### Conclusion from the observation

The targeted validation proves that one active app **local agent session** is present
in the local session store and has detailed token telemetry. The store has **6,748**
current usage-event rows with the field coverage stated above, but it still shows
**zero directly attributable “Copilot app” versus “CLI” aggregate counts**. The
`github`/`NULL` distribution cannot be relabelled as app/CLI counts: GitHub has not
documented `host_type` values or their semantics.

This resolves local-session feasibility while preserving the attribution boundary: a
known, directly validated app session is evidence for that current configuration; a
generic existing local event is not independently attributable to the app; and the
absence of an `app` `host_type` is not evidence that app data is absent.

### 5. Available metrics intentionally distinguish App from CLI

#### Verified

GitHub's organization/enterprise usage-metrics schema has separate `used_cli` and
`used_copilot_app` booleans, and separate `totals_by_cli` and
`totals_by_copilot_app` objects. Each surface has distinct session, request, prompt,
and token aggregate fields.
[Copilot usage-metrics fields](https://docs.github.com/en/copilot/reference/copilot-usage-metrics/copilot-usage-metrics#per-user-report-fields),
[Copilot CLI metrics fields](https://docs.github.com/en/copilot/reference/copilot-usage-metrics/copilot-usage-metrics#copilot-cli-metrics-fields),
[Copilot app metrics fields](https://docs.github.com/en/copilot/reference/copilot-usage-metrics/copilot-usage-metrics#copilot-app-metrics-fields)

The same reference says its dashboards do not include CLI usage; metrics reports/API
are aggregate organization or enterprise data rather than a personal session API.
[Copilot usage-metrics overview](https://docs.github.com/en/copilot/reference/copilot-usage-metrics/copilot-usage-metrics#github-copilot-usage-dashboard-metrics),
[API and export fields](https://docs.github.com/en/copilot/reference/copilot-usage-metrics/copilot-usage-metrics#api-and-export-fields)

#### Impact

Even though app agent sessions are CLI-backed, GitHub's official metrics attribution
treats **Copilot app** and **CLI** as different product surfaces. Tokenomics must not
roll local database totals into “Copilot app usage,” and must not use a shared runtime
as a reason to merge `totals_by_cli` with `totals_by_copilot_app`.

An authorized daily usage report can supply an app-level daily count and aggregate
input/output totals. It still cannot associate those totals with local session-store
rows or supply app per-turn cache/reasoning/latency values.

### 6. Revised reliable solution and required proof

#### Phase-one product behavior (proposal)

1. Read the local Copilot session store only after consent and only through the existing
   allowlisted numeric/metadata projection.
2. Name its source `copilotLocalSessionStore`, its fidelity `observedLocal`, and its
   session origin **unclassified**. Do not add `githubCopilotApp` based on
   `host_type`, `initiator`, or process naming.
3. Aggregate by observed local `session_id` and model. It is valid to display local
   session telemetry; it is not valid to calculate an app-specific total from all
   local-store records.
4. Use an authorized metrics report only to show separately labelled daily
   `totals_by_cli` and `totals_by_copilot_app` reconciliation values.
5. The direct local-agent-session result supports a version-pinned compatibility
   fixture. Broader app attribution still needs a version-gated, explicitly labelled
   *observed attribution heuristic*; do not call it a GitHub contract unless GitHub
   documents it.

#### Decisive, non-destructive experimental protocol (proposal)

Use a disposable repository and two deliberately labelled sessions. Record no
prompt/response/tool-output content in Tokenomics or experiment logs.

1. **Record compatibility baseline.** Capture app version, CLI version, OS, the
   database `PRAGMA schema_version`, table/column names, and total/grouped counts only.
2. **CLI control.** Create exactly one new CLI agent session. Through a read-only
   database connection, compare only newly created row counts and opaque IDs/timestamps
   held locally for the duration of the experiment. Observe whether a matching
   session-state directory appears.
3. **App local-workspace treatment.** Create exactly one new app **agent session** in
   a local worktree. Use the app workspace popover's documented actual CLI session ID.
   Compare only whether that opaque ID appears in `sessions`, has a matching
   session-state directory, and gains `assistant_usage_events`; record `host_type`
   without interpreting it.
4. **App chat treatment.** Create one app chat and repeat the metadata-only presence
   check. Do not assume chat and agent-session behavior match.
5. **App cloud-sandbox treatment.** Create one cloud-sandbox app session and repeat.
   Treat an absent local row as a valid result rather than reindexing, scraping, or
   changing sync settings.
6. **Handoff treatment.** Use the documented app/CLI session-history workflow where
   available and test identity continuity, selected model metadata, and harmless
   read-only tool behavior. Record mismatches as product behavior, not as schema
   defects.
7. **Metrics treatment.** On an authorized account/report day with isolated activity,
   compare daily `totals_by_cli` and `totals_by_copilot_app`; expect separate buckets
   under the published schema and do not allocate them to individual local rows.
8. **Repeat after upgrades.** Re-run after every app or CLI version upgrade. Any
   schema/identity change disables app attribution until reconfirmed.

The only success criterion for app attribution is a repeatable, version-pinned
experiment that observes a documented app-provided CLI session ID and corresponding
safe local metadata/event rows. Even that result supports a compatibility rule for the
tested configuration—not a universal claim for all app modes, chats, cloud sessions,
or future releases.

## Addendum — Automatic Copilot prompt-cache keepalive (2026-09-07)

**Decision:** Automatic Copilot keepalive is a desirable future scope, but it is **not
currently feasible or reliable** for Tokenomics to implement for active local GitHub
Copilot app or interactive CLI sessions. GitHub documents neither (a) an exact
per-session cache-expiry signal nor (b) a public external interface through which a
third-party macOS app can submit a prompt to an existing app/terminal session. Do not
use UI/terminal automation, screen scraping, clipboard injection, or undocumented
network/local-server calls to bridge those gaps.

This conclusion does not affect local telemetry monitoring. Tokenomics can safely
observe the local session-store fields described above; it cannot responsibly turn
that observation into autonomous cache-refresh behavior.

### 1. Documented Copilot cache behavior

#### Verified

GitHub documents prompt-cache expiry after inactivity of **24 hours for OpenAI models**
and **1 hour for most other models**. GitHub recommends preserving the cached portion
of the previous response instead of reprocessing it. It also documents cache
boundaries: switching models mid-session, changing reasoning/context/tool/MCP
configuration, and returning to an old session invalidate cache; Auto changes models
only at a new-session or post-`/compact` boundary.
[Optimizing AI usage — Preserve the cache](https://docs.github.com/en/copilot/tutorials/optimize-ai-usage#4-preserve-the-cache)

GitHub's supported-model catalog identifies models/providers but does not add a
product-specific or per-model TTL table.
[Supported AI models](https://docs.github.com/en/copilot/reference/ai-models/supported-models)

The documented CLI session indicators are running, busy, permission-needed,
waiting-for-user, and saved/resumable states. None indicates cache freshness, cache
hit/miss, or an expiry deadline.
[CLI session status indicators](https://docs.github.com/en/copilot/reference/copilot-cli-reference/cli-command-reference#session-status-indicators)

`/context` reports active-model context-window capacity and use; it is not a
prompt-cache freshness/TTL signal. The app's `/context` and `/usage` commands likewise
document context utilization and plan usage/rate-limit information, not cache expiry.
[Checking CLI context usage](https://docs.github.com/en/copilot/concepts/agents/copilot-cli/context-management#checking-your-context-usage),
[Copilot app slash commands](https://docs.github.com/en/copilot/reference/github-copilot-app-reference/slash-commands)

#### Unknown — do not infer

GitHub does **not** document that a trivial/no-op prompt refreshes the inactivity
timer, which cached prefix it would refresh, whether the same session must receive it,
or whether it would result in a cache hit. It also does not expose a user-visible
exact cache expiry timestamp or remaining-TTL field for app/CLI sessions.

The local `assistant_usage_events.cache_read_tokens` and `cache_write_tokens` fields
are useful telemetry but remain an undocumented local schema. They do not establish a
forward-looking cache deadline, and a nonzero value in one event is not an API promise
that a future heartbeat will retain cache.

### 2. Documented prompt dispatch paths, and why none supports Tokenomics keepalive

| Path | What is documented | Why it is not a Tokenomics automatic keepalive for an existing App/CLI session |
| --- | --- | --- |
| Interactive CLI `/every` | An experimental command that schedules a recurring prompt in the session that creates it; interval is 10 seconds to 1 day and it fires only while that CLI session remains running. | It must be configured from inside the session, schedules a visible real prompt, and is not a third-party dispatch API or documented cache-refresh primitive. |
| Scripted `copilot -p` / stdin | A documented noninteractive programmatic CLI run that processes a prompt and exits. | It creates a standalone run; GitHub does not say it attaches to, shares history with, or refreshes the cache of another interactive/App session. |
| App deep link | Can open an existing app session or open a confirmation-backed **new** session with a prompt. | GitHub documents no prompt/send operation for an already active App session. |
| CLI remote control | A signed-in user can use GitHub.com or GitHub Mobile to steer an active CLI session after enabling `/remote on`. | This is a first-party UI workflow; no public third-party API for automatic commands is documented. |
| Copilot SDK / headless CLI server | A host app can create/resume and `send` to a session it owns, through JSON-RPC to CLI server mode. | This supports a distinct SDK-owned workflow, not attachment to an App-owned or arbitrary terminal CLI session. Concurrent access to one SDK session is documented as undefined. |

Sources: [Scheduling prompts in Copilot CLI](https://docs.github.com/en/copilot/how-tos/copilot-cli/automate-copilot-cli/schedule-prompts),
[Running Copilot CLI programmatically](https://docs.github.com/en/copilot/how-tos/copilot-cli/automate-copilot-cli/run-cli-programmatically),
[Opening the Copilot app with deep links](https://docs.github.com/en/copilot/how-tos/github-copilot-app/open-with-deep-links),
[About CLI remote control](https://docs.github.com/en/copilot/concepts/agents/copilot-cli/about-remote-control),
[Copilot SDK](https://github.com/github/copilot-sdk), and
[SDK session-persistence limitations](https://docs.github.com/en/copilot/how-tos/copilot-sdk/features/session-persistence#limitations-and-considerations).

`/keep-alive` is not relevant to prompt cache: GitHub documents it as preventing a
machine from sleeping so remote control remains available.
[Preventing sleep during remote control](https://docs.github.com/en/copilot/how-tos/copilot-cli/use-copilot-cli/steer-remotely#preventing-your-machine-from-going-to-sleep)

### 3. Execution-environment implications

- **Copilot app local workspace/worktree:** the app supplies its own isolated
  workspace/session experience. A separately launched CLI has no documented authority
  to attach to its worktree, history, active session, or cache. The direct local-store
  validation above confirms telemetry materialization for the tested app local agent
  session, not external prompt-control authority.
- **Direct interactive CLI:** a user may configure `/every` in that same live session;
  it stops firing when the session stops. An external `copilot -p` run remains a
  different noninteractive invocation.
- **Copilot app cloud sandbox:** the execution environment is GitHub-hosted and
  isolated. `--cloud` is interactive-only and cannot be combined with `-p`, so a
  local scheduled process cannot use programmatic mode to ping a cloud session.
  [Cloud and local sandboxes](https://docs.github.com/en/copilot/concepts/about-cloud-and-local-sandboxes#cloud-sandboxing)
- **SDK-owned session:** a future Tokenomics-adjacent helper could technically own a
  separate local SDK session and schedule prompts, but this is not a keepalive for a
  user's existing App/CLI work and is outside the observer product boundary.

### 4. Cost, rate-limit, and side-effect risks

Each automatic prompt is an interaction that consumes model-dependent input, cached
input/cache-write, and output quantities before conversion to AI credits; GitHub
defines one AI credit as USD $0.01. A short requested response can still have nonzero
cost from its context/input. Cache reads are typically priced at 10% of normal input,
while some models additionally charge cache writes.
[GitHub AI credits](https://docs.github.com/en/copilot/concepts/billing/usage-based-billing-for-individuals#what-are-github-ai-credits),
[GitHub model pricing](https://docs.github.com/en/copilot/reference/copilot-billing/models-and-pricing)

GitHub cautions that frequent/automated requests can encounter usage limits and should
be adjusted. CLI session AI-credit limits are soft: an in-flight response may finish
and slightly exceed the configured amount.
[Usage limits](https://docs.github.com/en/copilot/concepts/usage-limits),
[CLI session limits](https://docs.github.com/en/copilot/how-tos/copilot-cli/use-copilot-cli/set-session-limit)

Even a constrained “reply `pong`; do not use tools” prompt is neither a documented
side-effect-free heartbeat nor hidden transport: it becomes session history/context,
can use tokens/credits, can collide with user or agent activity, and can alter later
context/compaction behavior.

### 5. Repository contrast and corrected scope

The existing feature is deliberately narrower than “automatic pings for all local
agents”:

- `Session.supportsCacheCountdown` is true only for `.claudeCode`; the countdown uses
  a local `cacheTouchTime` plus detected TTL. Codex can show a cached-input ratio but
  has no countdown. `Sources/Tokenomics/Models/Session.swift:239-267`
- `CodexSessionWatcher` is an observe-only local parser and constructs sessions with
  `cacheTouchTime: nil` and `detectedTTL: nil`.
  `Sources/Tokenomics/Services/CodexSessionWatcher.swift:3-4`,
  `Sources/Tokenomics/Services/CodexSessionWatcher.swift:31-116`
- The current Claude keepalive is an implementation-specific heuristic: it uses the
  estimated TTL, eligible idle/waiting states, and a capped ping budget.
  `Sources/Tokenomics/Services/KeepAliveTracker.swift:41-66`,
  `Sources/Tokenomics/Services/KeepAliveTracker.swift:170-180`

**Correction:** do not extend the existing automatic-ping mechanism to Copilot merely
because local cache-token counters exist. Copilot monitoring is feasible; automatic
Copilot keepalive is a desired future scope only, pending **both** an exact
user-visible/programmable expiry signal and a documented, safe external dispatch API
for the already-active session.

### 6. Revised plan: monitoring now, optional keepalive only after proof

#### Phase A — safe local monitoring (recommended)

Implement the consented, read-only `copilotLocalSessionStore` watcher from the main
plan: runtime schema detection, numeric/metadata allowlist, versioned fixtures,
schema-fingerprint diagnostics, WAL-safe retries, and graceful unavailable status.
Display observed cache-read/cache-write values and event timing as history, without a
countdown or refresh action.

**Acceptance criteria**

- No code path sends a Copilot prompt, focuses an app window/terminal, changes
  clipboard content, or changes Copilot settings.
- No UI reports cache expiry, cache warmth, or a billed cost as known.
- Missing/drifted tables and nullable `reasoning_tokens` degrade without fabricated
  zeros or automatic writes.

#### Phase B — user-directed CLI guidance (safe optional aid)

If useful, offer documentation that a user may manually enable CLI `/every` in an
interactive session. Do not configure it programmatically, prefill a prompt without
confirmation, or characterize it as a cache guarantee.

**Acceptance criteria**

- The UI distinguishes GitHub's experimental scheduling feature from Tokenomics.
- Guidance includes its running-session requirement and billing/rate-limit warning.

#### Phase C — automatic keepalive reconsideration gate (not approved)

Reconsider only if GitHub documents all of the following:

1. an exact per-session cache expiry/freshness signal;
2. whether and how a refresh prompt preserves the target cache;
3. a supported authenticated API to send a controlled input to an existing App or
   interactive CLI session; and
4. side-effect, concurrency, rate-limit, and billing semantics.

Until then, a Tokenomics automatic keepalive must remain disabled/unimplemented.

### 7. Controlled local experiments (evidence, not a product guarantee)

1. In a disposable worktree, create an interactive CLI test session with a fixed
   model/configuration. Manually enable experimental mode and configure the documented
   `/every` command with a harmless, tool-free response request; keep the same
   terminal session running.
2. Maintain a comparable cold-control session without `/every`; leave it inactive
   beyond GitHub's documented model-family interval. Compare only safe observation
   data (event timestamps, numeric token buckets, visible session state, and
   user-initiated `/context` output), not prompt/tool content.
3. Repeat with a model/configuration change to confirm the documented cache-boundary
   behavior. Do not treat `/context` or one cache-read event as proof of refresh.
4. Test a separately owned SDK/headless-CLI session with serialized sends and a
   single-writer queue. Do not attach to or dispatch into the App's runtime.
5. Repeat only after CLI/App/model updates. A positive test result is a
   version/configuration observation, never evidence that arbitrary trivial pings
   reliably reset Copilot cache retention.

## Primary-source reference set

1. [About GitHub Copilot CLI](https://docs.github.com/en/copilot/concepts/agents/copilot-cli/about-copilot-cli)
2. [About GitHub Copilot CLI session data](https://docs.github.com/en/copilot/concepts/agents/copilot-cli/chronicle)
3. [Using GitHub Copilot CLI session data and Chronicle](https://docs.github.com/en/copilot/how-tos/copilot-cli/use-copilot-cli/chronicle)
4. [GitHub Copilot CLI configuration directory](https://docs.github.com/en/copilot/reference/copilot-cli-reference/cli-config-dir-reference)
5. [GitHub Copilot CLI command reference](https://docs.github.com/en/copilot/reference/copilot-cli-reference/cli-command-reference)
6. [REST API endpoints for Copilot usage metrics](https://docs.github.com/en/rest/copilot/copilot-usage-metrics)
7. [Data available in Copilot usage metrics](https://docs.github.com/en/copilot/reference/copilot-usage-metrics/copilot-usage-metrics)
8. [Example schema for Copilot usage metrics](https://docs.github.com/en/copilot/reference/copilot-usage-metrics/example-schema)
9. [Usage-based billing for individuals](https://docs.github.com/en/copilot/concepts/billing/usage-based-billing-for-individuals)
10. [Usage-based billing for organizations and enterprises](https://docs.github.com/en/copilot/concepts/billing/organizations-and-enterprises/usage-based-billing)
11. [Models and pricing for GitHub Copilot](https://docs.github.com/en/copilot/reference/copilot-billing/models-and-pricing)
12. [Legacy request-based billing](https://docs.github.com/en/copilot/reference/copilot-billing/request-based-billing-legacy/copilot-requests)
13. [About Copilot auto model selection](https://docs.github.com/en/copilot/concepts/models/auto-model-selection)
14. [Changing the AI model for Copilot cloud agent](https://docs.github.com/en/copilot/how-tos/use-copilot-agents/cloud-agent/changing-the-ai-model)
15. [About GitHub Copilot cloud agent](https://docs.github.com/en/copilot/concepts/agents/cloud-agent/about-cloud-agent)
16. [About third-party coding agents](https://docs.github.com/en/copilot/concepts/agents/about-third-party-coding-agents)
17. [Official GitHub Copilot CLI releases](https://github.com/github/copilot-cli/releases)
18. [Working with agent sessions in the GitHub Copilot app](https://docs.github.com/en/copilot/how-tos/github-copilot-app/agent-sessions)
19. [GitHub Copilot app repository and release notes](https://github.com/github/app)
20. [GitHub Copilot SDK](https://github.com/github/copilot-sdk)
21. [Working with multiple Copilot CLI sessions](https://docs.github.com/en/copilot/how-tos/copilot-cli/use-copilot-cli/work-with-multiple-sessions)
22. [Optimizing AI usage in GitHub Copilot](https://docs.github.com/en/copilot/tutorials/optimize-ai-usage)
23. [Supported AI models](https://docs.github.com/en/copilot/reference/ai-models/supported-models)
24. [Scheduling prompts in Copilot CLI](https://docs.github.com/en/copilot/how-tos/copilot-cli/automate-copilot-cli/schedule-prompts)
25. [Running Copilot CLI programmatically](https://docs.github.com/en/copilot/how-tos/copilot-cli/automate-copilot-cli/run-cli-programmatically)
26. [Using deep links to open the Copilot app](https://docs.github.com/en/copilot/how-tos/github-copilot-app/open-with-deep-links)
27. [About Copilot CLI remote control](https://docs.github.com/en/copilot/concepts/agents/copilot-cli/about-remote-control)
28. [Copilot SDK session persistence](https://docs.github.com/en/copilot/how-tos/copilot-sdk/features/session-persistence)
29. [Cloud and local sandboxes](https://docs.github.com/en/copilot/concepts/about-cloud-and-local-sandboxes)
30. [GitHub Copilot usage limits](https://docs.github.com/en/copilot/concepts/usage-limits)
31. [Setting a Copilot CLI session limit](https://docs.github.com/en/copilot/how-tos/copilot-cli/use-copilot-cli/set-session-limit)
