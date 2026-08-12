import SwiftUI

/// One card's worth of advice in the Token Optimization window (see TOKEN_TIPS.md, the source
/// this view is a condensed, native-UI rendering of).
private struct TokenTip: Identifiable {
    let id: Int
    let icon: String
    let title: String
    let points: [String]
}

/// One tab in the Token Optimization window. Add a case here + its tip array to add an agent.
private enum CodingAgent: String, CaseIterable, Identifiable {
    case claudeCode = "Claude Code"
    case codex = "Codex"

    var id: String { rawValue }
}

private let claudeCodeTips: [TokenTip] = [
    TokenTip(id: 1, icon: "bolt.fill", title: "Prompt caching", points: [
        "Cache writes cost ~1.25x (5-min TTL) or ~2x (1-hour TTL) base input price; cache reads cost only ~0.1x — about a 90% discount.",
        "TTL is set by how Claude Code itself was launched (ENABLE_PROMPT_CACHING_1H), not by this app — the cache badge in the session list reads the real, detected TTL.",
        "Only the TTL expires a cache with no request involved. Everything else below is a prefix mismatch on the next turn, not a background eviction.",
        "Full reset: switching models mid-conversation, or adding/removing/reordering a tool or MCP server.",
        "Partial reset: editing the system prompt (tools stay cached; system + messages rewrite).",
        "Cheap reset: tool_choice, adding an image, or toggling thinking on/off — only the message-turns cache rewrites.",
        "CLAUDE.md is read once at session start, not every turn — a mid-session edit has no effect until /compact re-reads it (project root only).",
    ]),
    TokenTip(id: 2, icon: "rectangle.compress.vertical", title: "Context management: /compact & /clear", points: [
        "The whole context window is resent on every turn, so its size is a direct per-message cost multiplier.",
        "/clear between unrelated tasks avoids paying to resend a finished task's history.",
        "/compact focus on X summarizes older turns while keeping what you specify — do it right after a big tool dump.",
    ]),
    TokenTip(id: 3, icon: "stethoscope", title: "/usage, /context, /doctor", points: [
        "/usage — token counts by input/output/cache write/cache read, cost, and per-model/skill/subagent attribution.",
        "/context — what's actually occupying the context window right now: CLAUDE.md, memory, history, tool schemas.",
        "/doctor — flags an oversized CLAUDE.md or unused MCP servers quietly costing tokens on every request.",
    ]),
    TokenTip(id: 4, icon: "cpu", title: "Model selection", points: [
        "Use a Haiku-class model for mechanical work — linting, formatting, simple edits — roughly an order of magnitude cheaper.",
        "Reserve the top-tier model for hard reasoning/design work; the mid-tier model is the right default otherwise.",
        "Subagents can override the model independently of the main session — force cheap research work onto a cheaper model.",
    ]),
    TokenTip(id: 5, icon: "person.2.fill", title: "Delegate to subagents", points: [
        "A subagent gets its own context window and returns only a summary — raw tool output never enters your main conversation.",
        "Push anything with large, disposable output (test runs, codebase exploration, fetched pages) into a subagent.",
        "This compounds: a 5,000-line log kept inline costs its full size on every following turn; a subagent summary costs that once.",
    ]),
    TokenTip(id: 6, icon: "magnifyingglass", title: "Tool-output & file-read hygiene", points: [
        "Grep for what you need instead of reading whole files.",
        "Read specific line ranges of large files rather than the whole thing.",
        "Pipe noisy commands through head/tail so only relevant lines enter context.",
    ]),
    TokenTip(id: 7, icon: "doc.text", title: "Keep CLAUDE.md lean", points: [
        "It's injected into every request in the project — its size is a permanent per-turn tax.",
        "Only write down what can't be derived by reading the code: non-obvious constraints, gotchas, real conventions.",
        "Move path-specific instructions into scoped rules that only load when relevant files are touched.",
    ]),
    TokenTip(id: 8, icon: "puzzlepiece.extension.fill", title: "MCP tools load lazily", points: [
        "Only tool names load into context at session start; full parameter schemas load on demand when a tool is actually called.",
        "Still disable MCP servers you aren't using for a given project — even deferred names add up across many servers.",
    ]),
    TokenTip(id: 9, icon: "clock.arrow.circlepath", title: "Batch API for non-interactive work", points: [
        "Anthropic's Message Batches API runs requests asynchronously at roughly half the per-token price.",
        "Good for overnight bulk review, scheduled reports, offline analysis — not for interactive coding sessions.",
    ]),
    TokenTip(id: 10, icon: "text.bubble.fill", title: "Output tokens cost more than input", points: [
        "Output tokens are commonly billed ~3-5x the input rate, and reasoning/\"thinking\" tokens are billed as output too.",
        "Ask for concise answers when that's all you need, and lower reasoning effort for mechanical tasks.",
    ]),
    TokenTip(id: 11, icon: "terminal.fill", title: "rtk (Rust Token Killer)", points: [
        "This app already reads rtk gain's measured savings per project — a hook rewrites common shell commands to cut their output before it reaches the model.",
        "If rtk isn't installed, none of that command-level filtering happens — installing it is close to a free win for shell-heavy sessions.",
    ]),
    TokenTip(id: 12, icon: "sparkles", title: "Skills: scoped, on-demand context", points: [
        "A skill's instructions load only when invoked, unlike a global CLAUDE.md which sits in context for the whole session.",
        "Preferring a skill over equivalent CLAUDE.md instructions keeps the steady-state per-turn cost down.",
    ]),
]

private let codexTips: [TokenTip] = [
    TokenTip(id: 1, icon: "bolt.fill", title: "Prompt caching is automatic", points: [
        "OpenAI's API caches long prompt prefixes automatically once a request is long enough (roughly 1,000+ tokens) — no manual cache_control marker to set.",
        "Only an exact prefix match hits the cache — put stable content (system instructions, AGENTS.md, tool definitions) first and per-turn content last.",
        "Cached tokens are meaningfully cheaper than fresh ones, though the exact discount varies by model.",
        "Idle time still evicts the cache after a period of inactivity — the same \"keep the session warm\" advice as Claude Code applies.",
    ]),
    TokenTip(id: 2, icon: "rectangle.compress.vertical", title: "Context management: /compact, /clear, /new", points: [
        "/compact summarizes the visible transcript to free up context — the direct analog of Claude Code's /compact.",
        "/clear clears the terminal and starts fresh; /new starts a new chat without wiping the scrollback.",
        "Codex CLI can also auto-compact past a configured token threshold — manual /compact controls when that happens.",
    ]),
    TokenTip(id: 3, icon: "stethoscope", title: "/status, /usage", points: [
        "/status shows the active model, approval policy, and how much context capacity is left in the session.",
        "/usage shows account-level token usage and when rate limits reset.",
    ]),
    TokenTip(id: 4, icon: "cpu", title: "Model and reasoning-effort selection", points: [
        "/model switches both the active model and its reasoning effort mid-session.",
        "Reasoning effort (minimal/low/medium/high, naming varies by model) is the same lever as Anthropic's effort parameter.",
        "Cheaper model tiers exist alongside the flagship coding model — reserve the expensive one for hard work.",
    ]),
    TokenTip(id: 5, icon: "slider.horizontal.3", title: "Config-level cost controls", points: [
        "A per-tool-output token cap keeps one huge command's output from consuming the whole context budget on a single turn.",
        "Approval policy and sandbox mode don't save tokens directly, but fewer interactive round-trips means fewer billed turns.",
        "History/transcript size caps bound the on-disk session log, separate from what's actually sent to the model.",
    ]),
    TokenTip(id: 6, icon: "doc.text", title: "Keep AGENTS.md lean", points: [
        "AGENTS.md is injected into every turn, the same way CLAUDE.md is for Claude Code.",
        "Write only what can't be derived from the code — the same lean-instructions discipline applies verbatim.",
    ]),
    TokenTip(id: 7, icon: "text.bubble.fill", title: "Output tokens cost more than input", points: [
        "Generated output is billed at a materially higher per-token rate than the prompt you sent in.",
        "Ask for concise answers when that's all you need, and skip high reasoning effort for tasks that don't need it.",
    ]),
    TokenTip(id: 8, icon: "clock.arrow.circlepath", title: "Batch processing for non-interactive work", points: [
        "OpenAI's async batch endpoints offer a substantial discount for work that doesn't need an immediate answer.",
        "A lever for scripted/API automation, not for an interactive CLI session itself.",
    ]),
]

private func tips(for agent: CodingAgent) -> [TokenTip] {
    switch agent {
    case .claudeCode: return claudeCodeTips
    case .codex: return codexTips
    }
}

/// The app's Token Optimization window, opened from the footer's "Token optimization…" row.
/// One tab per coding agent (see `CodingAgent`); each tab condenses TOKEN_TIPS.md's matching
/// section into scannable cards. Kept in sync by hand — the markdown is the research source of
/// record and this view is just its in-app presentation.
struct TokenTipsView: View {
    @State private var selectedAgent: CodingAgent = .claudeCode

    var body: some View {
        VStack(spacing: 0) {
            header
            Picker("Agent", selection: $selectedAgent) {
                ForEach(CodingAgent.allCases) { agent in
                    Text(agent.rawValue).tag(agent)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 24)
            .padding(.top, 12)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(tips(for: selectedAgent)) { tip in
                        TokenTipCard(tip: tip)
                    }
                }
                .padding(24)
            }
        }
        .frame(width: 560, height: 640)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Token Optimization")
                .font(.system(size: 20, weight: .semibold))
            Text("Practical ways to cut coding-agent token usage and cost, ranked roughly by impact.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 24)
        .padding(.top, 24)
    }
}

private struct TokenTipCard: View {
    let tip: TokenTip

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: tip.icon)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 18)
                Text("\(tip.id). \(tip.title)")
                    .font(.system(size: 14, weight: .semibold))
            }

            VStack(alignment: .leading, spacing: 5) {
                ForEach(tip.points, id: \.self) { point in
                    HStack(alignment: .top, spacing: 6) {
                        Text("•")
                            .foregroundStyle(.secondary)
                        Text(point)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(.leading, 26)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.04)))
    }
}
