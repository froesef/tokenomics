## Token Optimization Tips

Research notes behind the in-app "Token optimization" window. Each agent gets its own tab in the
app; sections below are grouped the same way. Ordered roughly by impact within each agent.

## Claude Code

### 1. Prompt caching

Anthropic's API caches repeated prefixes of a request (system prompt, tools, early conversation
turns) server-side, so you pay full price once and a fraction of it on every re-use.

- **Cache writes cost more, cache reads cost far less.** A write costs ~1.25x the base input-token
  price at the default 5-minute TTL, or ~2x for the optional 1-hour TTL. A cache *hit* costs only
  ~0.1x base input price — roughly a 90% discount versus sending those tokens fresh.
- **TTL is set by how Claude Code was launched, not by this app.** A 1-hour TTL needs
  `ENABLE_PROMPT_CACHING_1H`; otherwise it's the 5-minute default. Tokenomics reads the *actual*
  TTL per session straight from the transcript (`Session.detectedTTL`) rather than letting you
  configure it, because that number reflects reality, not a preference.
- **Minimum cacheable size varies by model** (roughly 1,024 tokens for Haiku-class models, 512 for
  the largest models) — very short prompts can't be cached at all.
- **The lever is idle time.** Every gap longer than the TTL lets the cache expire, so the next
  request re-writes the full prefix at the higher write price. This is exactly what the warm /
  expiring-soon / cold indicator in the session list is showing you: keep working inside a session
  before it goes cold, and batch or defer follow-ups until you're back at the keyboard rather than
  trickling in one message every ten minutes.
- **Keep the cached prefix stable.** Anything before the cache breakpoint (system prompt, tool
  definitions, CLAUDE.md) that changes between requests busts the cache and forces a rewrite. Edit
  CLAUDE.md and tool configs between sessions, not mid-session.
- **What actually resets (invalidates) a cache, per Anthropic's own invalidation table:**
  - **Full reset** (tools + system + message history all rewritten): switching the **model**
    mid-conversation — caches are model-scoped, no exceptions — or changing the **tool
    list/MCP servers** (add, remove, or reorder any tool).
  - **Partial reset** (system + messages rewritten, but the already-cached tool definitions
    survive): editing the **system prompt** itself.
  - **Cheap reset** (only the message-turns cache rewrites; tools and system stay cached):
    toggling `tool_choice`, adding/changing an image or document in the conversation, or
    flipping extended thinking on/off. Changing the **effort** level isn't listed explicitly in
    Anthropic's table, but it's a request parameter rather than rendered prompt content, so it
    likely falls in this same cheap tier — treat this one specific claim as a reasonable
    inference, not a documented guarantee.
  - **CLAUDE.md specifically:** Claude Code reads it once at session start, not every turn — a
    mid-session edit isn't even picked up until `/compact` re-reads the project-root file (nested
    CLAUDE.md files don't reload even then) or a new session starts. So a stray edit doesn't
    retroactively bust anything; it just has no effect until the next re-read, at which point it's
    an ordinary system-prompt change (the "partial reset" case above).
  - **The only thing that expires a cache entry with no request involved is the TTL itself**
    (5 min default, 1 hour with the extended option) — everything above is a *prefix mismatch*
    on the next request, not a background eviction. A reverted change can still hit an old,
    not-yet-expired entry.

### 2. Context management: `/compact` and `/clear`

The entire context window is resent on every turn, so its size is a direct cost multiplier — a
100KB conversation costs 100KB of input tokens on *every single message*, not just once.

- `/clear` wipes context completely — use it between unrelated tasks so you're not paying to
  resend a finished task's history while starting a new one.
- `/compact` summarizes older turns while preserving what you tell it to keep (e.g.
  `/compact focus on the API changes`) — better than an uncontrolled auto-compaction because you
  choose what survives.
- Claude Code auto-compacts as the context fills, dropping bulky tool output first, then
  summarizing older messages. Letting it auto-compact is fine, but proactively compacting after a
  large tool dump (test output, a big grep, a fetched doc) keeps every subsequent turn cheaper.
- Long-running sessions with big transcripts are exactly where Tokenomics' per-session token
  breakdown is most useful — a session sitting on a huge, largely-idle context is a candidate for
  `/clear` and a fresh start.

### 3. Built-in visibility: `/usage`, `/context`, `/doctor`

Claude Code has commands purpose-built to answer "where did my tokens go":

- **`/usage`** — session token counts split by input / output / cache write / cache read, plus
  estimated cost. Shows per-model and per-skill/subagent/MCP-server attribution. Press `d`/`w` to
  toggle 24h/7-day views.
- **`/context`** — a breakdown of what's currently occupying the context window: CLAUDE.md,
  auto-memory, conversation history, deferred vs. loaded tool schemas. The fastest way to find out
  *why* a session feels expensive.
- **`/doctor`** — a configuration health check; flags things like an oversized CLAUDE.md or unused
  MCP servers that are quietly consuming context on every request.

### 4. Model selection

Model choice is one of the biggest cost levers, because per-token price differs by multiples
between tiers.

- Use Haiku-class models for mechanical work — linting, formatting, simple edits, log filtering.
  It's roughly an order of magnitude cheaper than the mid-tier model.
- Reserve the top-tier model for genuinely hard reasoning/design work; the mid-tier model is the
  right default for most day-to-day coding.
- Subagents can override the model independently of the main session (e.g. force a research
  subagent onto a cheaper model) — useful when the delegated work doesn't need the main session's
  model at all.
- Switch mid-session with `/model` rather than starting a whole new session on the wrong tier.

### 5. Delegate to subagents

Every subagent gets its own, separate context window and returns only a summary — the raw tool
output it generated (test logs, fetched pages, file dumps) never enters your main conversation.

- Push anything that produces large, disposable output — running a test suite, exploring an
  unfamiliar codebase, fetching a web page — into a subagent instead of doing it inline.
- The main session then only pays for the summary, once, instead of paying to resend the full raw
  output on every subsequent turn for the rest of the session.
- This compounds: a 5,000-line log kept inline costs its full size on *every following turn*; the
  same work done in a subagent costs a 50-line summary, once.

### 6. Tool-output and file-read hygiene

- Grep for what you need instead of reading whole files (`grep ERROR big.log` vs. `cat big.log`).
- Read specific line ranges of large files rather than the whole thing when you only need one
  function or section.
- Pipe noisy commands through `head`/`tail` or a filter so only the relevant lines enter context.
- Avoid re-reading files that haven't changed since your last read — trust what's already in
  context.

### 7. Keep CLAUDE.md lean

CLAUDE.md is injected into *every* request in the project, so its size is a permanent per-turn tax.

- Keep it short — a few hundred lines at most. Put anything path-specific into scoped rules that
  only load when relevant files are touched, instead of one file loaded unconditionally.
- Only write down what Claude can't derive by reading the code: non-obvious constraints, gotchas,
  conventions that differ from the ecosystem default. Skip descriptions of things already evident
  from the repo (directory layout, tech stack).
- `/doctor` will flag an oversized CLAUDE.md as a specific optimization opportunity.

### 8. MCP tools load lazily

Modern Claude Code defers MCP tool schemas: only tool *names* are loaded into context at session
start, and the full parameter schema for a given tool is fetched only when it's actually about to
be called.

- A session with 50 MCP tools available pays for ~50 short names up front, not 50 full schemas —
  the schemas are pulled in on demand.
- Still, disable MCP servers you aren't using for a given project; even deferred tool names add up
  across many servers, and an unused server is pure overhead.

### 9. Batch API for non-interactive work

Anthropic's Message Batches API runs requests asynchronously (results in minutes-to-hours, not
seconds) at roughly **half** the per-token price of standard synchronous requests.

- Good fit for anything that doesn't need an immediate answer: overnight bulk code review,
  scheduled report generation, large-scale offline analysis.
- Not a fit for interactive coding sessions — this is a lever for scripted/scheduled workloads
  built on top of the API, not for Claude Code itself.

### 10. Output tokens cost more than input tokens

Output tokens are billed at a materially higher rate than input tokens (commonly ~3-5x), and
"thinking"/reasoning tokens are billed as output too.

- Ask for concise answers when a short answer is all you need — "summarize in three bullets"
  costs less than an open-ended "explain everything."
- Lower the reasoning effort for simple, mechanical tasks; save higher effort for problems that
  actually need it.
- A verbose back-and-forth generates cost on both sides of the ledger, but the output half is the
  more expensive half — the biggest single win is avoiding unnecessarily long generations, not
  just short prompts.

### 11. `rtk` (Rust Token Killer)

This app already shells out to `rtk gain` per project directory to show real, measured savings
(`RTKService.swift`) — it's a token-optimized CLI proxy that rewrites common shell commands (via a
Claude Code hook) to cut their output before it ever reaches the model, reporting the percentage
and absolute tokens saved per command. If `rtk` isn't installed, none of that command-level
filtering is happening — installing it is close to a free win for any shell-heavy session.

### 12. Skills as scoped, on-demand context

Skills (like this project's own workflow for structured tasks, or things like `graphify` for
turning a codebase into a queryable knowledge graph) load their instructions only when invoked,
rather than sitting in context for the whole session the way a global CLAUDE.md does. Preferring a
skill over baking equivalent instructions into CLAUDE.md keeps the steady-state per-turn cost down
and only pays the extra context when that specific workflow is actually in use.

## Codex CLI

OpenAI's `codex` CLI (and the underlying Responses API it's built on) shares the same broad levers
as Claude Code — caching, context size, model tier, output verbosity — but the mechanics and
command names differ. Exact current model names and discount percentages move fast enough that
they're deliberately left out below; treat this section as "where to look," not a pinned number.

### 1. Prompt caching is automatic — no manual cache markers

Unlike Anthropic's explicit `cache_control` breakpoints, OpenAI's API caches long prompt prefixes
automatically once a request is long enough (roughly 1,000+ tokens), keyed off a hash of the
prefix. There's nothing to configure to turn it on.

- **Ordering still matters.** Only an exact prefix match hits the cache, so put stable content
  (system instructions, AGENTS.md, tool definitions) first and anything that varies per turn
  (the specific question, a timestamp, freshly-fetched data) last — exactly the same
  cache-placement discipline as Claude Code, just without an explicit marker to place.
- **Cached tokens are meaningfully cheaper than fresh ones**, though the exact discount varies by
  model and isn't worth memorizing a specific number for — it moves with pricing updates.
- **Idle time is still the enemy.** Cache entries are evicted after a period of inactivity
  (commonly on the order of minutes), so the same "keep working inside a session, don't let it
  sit cold" advice from tip #1 above applies here too.

### 2. Context management: `/compact`, `/clear`, `/new`

- `/compact` summarizes the visible transcript to free up context — the direct analog of Claude
  Code's `/compact`.
- `/clear` clears the terminal and starts fresh; `/new` starts a new chat without wiping the
  visible terminal scrollback.
- Codex CLI can also auto-compact once the transcript crosses a configured token threshold, so
  manual `/compact` is a way to control *when* that happens rather than the only way it happens.

### 3. Built-in visibility: `/status`, `/usage`

- `/status` shows the active model, approval policy, and how much context capacity is left in the
  current session — the quickest way to see a session heading toward a forced compaction.
- `/usage` shows account-level token usage and when rate limits reset.

### 4. Model and reasoning-effort selection

- `/model` switches both the active model and its reasoning effort mid-session, without starting
  over.
- Reasoning effort (minimal/low/medium/high, naming varies by model) is the same lever as
  Anthropic's `effort` parameter — lower it for mechanical edits, raise it for genuinely hard
  problems.
- Cheaper model tiers exist alongside the flagship coding model, the same "reserve the expensive
  model for hard work" logic from the Claude Code section applies.

### 5. Config-level cost controls

Codex CLI's config file (`~/.codex/config.toml` or a project-local `.codex/config.toml`) exposes
several settings worth knowing about even if you never touch the numeric defaults:

- A per-tool-output token cap keeps a single huge command's output (a build log, a big grep) from
  silently consuming the whole context budget on one turn.
- Approval policy and sandbox mode (e.g. auto-approving trusted commands vs. asking every time)
  don't save tokens directly, but fewer interactive round-trips means fewer turns billed overall.
- History/transcript size caps bound how large the on-disk session log grows, separate from what's
  actually sent to the model.

### 6. Keep AGENTS.md lean

Codex CLI reads project- and user-level `AGENTS.md` files the same way Claude Code reads
`CLAUDE.md` — injected into every turn. Everything in tip #7 of the Claude Code section (keep it
short, write only what can't be derived from the code) applies verbatim here.

### 7. Output tokens cost more than input tokens

Same shape as Claude Code: generated output is billed at a materially higher per-token rate than
the prompt you sent in. Ask for concise answers when that's all you need, and don't run at a high
reasoning effort for tasks that don't need it — both cut the more expensive half of the bill.

### 8. Batch processing for non-interactive workloads

OpenAI's async batch endpoints offer a substantial discount (commonly cited around half price) for
work that doesn't need an immediate answer — the same shape as Anthropic's Batch API. This is a
lever for scripted/API automation built around Codex-style workflows, not for an interactive CLI
session itself.
