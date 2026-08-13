import Foundation

enum AgentKind: Equatable, Sendable {
    case claudeCode
    case codex

    var displayName: String {
        switch self {
        case .claudeCode: return "Claude Code"
        case .codex: return "Codex"
        }
    }
}

/// What a session actually used, parsed from `tool_use` blocks in the transcript's assistant messages —
/// surfaced so a user can see what's making a session efficient (or not): leaning on plugins/skills vs.
/// brute-forcing everything through Bash, etc.
struct ToolUsage: Equatable, Sendable {
    /// Built-in tool name -> number of times called (e.g. "Bash": 42). Excludes MCP/plugin tools and the
    /// Skill tool, which are broken out separately below since "which plugin/skill" is more informative
    /// than "called the generic Skill tool N times".
    var builtInTools: [String: Int] = [:]
    /// MCP server names, parsed from `mcp__<server>__<tool>` tool names.
    var mcpServers: Set<String> = []
    /// Skill names invoked via the Skill tool's `input.skill`.
    var skills: Set<String> = []
    /// Hook binary name -> invocation count, parsed from `hook_success`/`hook_error` attachment events
    /// (e.g. "rtk" from a `PreToolUse:Bash` hook whose `command` is "rtk hook claude"). Hooks are a
    /// distinct mechanism from MCP/Skills — they run transparently around a tool call rather than being
    /// a tool the model chose to invoke, so they don't show up as `tool_use` blocks at all.
    var hooks: [String: Int] = [:]

    var isEmpty: Bool { builtInTools.isEmpty && mcpServers.isEmpty && skills.isEmpty && hooks.isEmpty }
}

/// One cold-cache rewrite observed in a transcript: a turn whose prompt cache had gone cold (the session
/// sat idle longer than its TTL), so the entire cached prefix had to be re-written at cache-write price
/// instead of served as a cheap cache read. This is the quantified form of the app's core thesis — an
/// idle gap that let the cache expire cost real money on the next turn.
///
/// Detected in `TranscriptWatcher.loadSession`; see there for the exact signal (a per-turn gap longer than
/// the detected TTL, combined with `cache_read_input_tokens == 0` and a substantial
/// `cache_creation_input_tokens` on the turn after the gap — and never the unavoidable first write of a
/// session). Priced via `Pricing.coldRewriteCostUSD`.
struct CacheExpiryEvent: Equatable, Sendable {
    /// Timestamp of the cold turn (the one that paid the rewrite), used to scope the meter to "today".
    let time: Date
    /// `cache_creation_input_tokens` on that turn — the whole prefix that had to be rewritten. Exact.
    let wastedTokens: Int
    /// Model that answered the cold turn, for per-model pricing. Nil if the transcript didn't record one.
    let model: String?
    /// TTL in effect on the cold turn, which sets the cache-write multiplier used to price the waste.
    let ttl: TimeInterval
}

/// One coding-agent session: one transcript file or rollout, one working directory, and any cache usage
/// metadata the source format exposes.
struct Session: Identifiable, Equatable, Sendable {
    let id: String
    /// Which coding agent wrote this session's transcript — see AgentIcon.swift. Always `.claudeCode`
    /// for Claude transcripts and `.codex` for local Codex rollouts, kept on the model rather than
    /// assumed by the views so each watcher can report its source explicitly.
    var agentKind: AgentKind = .claudeCode
    let workingDirectory: String
    /// Claude Code's own AI-generated summary of what the session is doing (from the transcript's
    /// `ai-title` event) — the same short label it uses as the Ghostty tab title. Nil until Claude Code
    /// has generated one, which usually happens after the first exchange.
    let aiTitle: String?
    let lastTurnTime: Date
    /// Timestamp of this session's most recent *assistant* turn (a response that carried `usage`), as
    /// opposed to `lastTurnTime`, which also advances on user events — including the echoed prompt of an
    /// auto keep-alive ping. KeepAliveTracker relies on this to tell a ping's actual *answer* apart from
    /// its own prompt echo when deciding whether the ping landed. `.distantPast` until the first assistant
    /// turn (and for Codex rows, which don't drive keep-alive).
    var lastAssistantTurnTime: Date = .distantPast
    let cacheCreationTokens: Int
    let cacheReadTokens: Int
    /// Codex token totals from `event_msg/token_count` records. For OpenAI usage, `input_tokens` already
    /// includes cached input; `cached_input_tokens` is the discounted subset. Claude Code rows leave these
    /// nil because their transcript exposes cache-write/cache-read counters instead.
    let totalInputTokens: Int?
    let cachedInputTokens: Int?
    let outputTokens: Int?
    let reasoningOutputTokens: Int?
    let toolUsage: ToolUsage
    /// Model id (e.g. "claude-sonnet-5") and reasoning-effort level (e.g. "high") from the most recent
    /// assistant turn — read straight from the transcript (`message.model` / top-level `effort` on each
    /// `assistant` event), not inferred. Nil until at least one assistant turn has happened.
    let model: String?
    let effort: String?
    /// Claude Code CLI version that wrote the most recent line of this transcript — read straight off the
    /// top-level `"version"` field present on every event (confirmed by inspecting a real transcript), not
    /// inferred. Nil only if the transcript predates that field.
    let version: String?
    /// Character count of the most recent assistant reply that actually had visible text (i.e. a `text`
    /// content block, not just `thinking`/`tool_use`) — a proxy for "how much there was to read last
    /// time," used to scale how early a warning fires. Deliberately text length, not `usage.output_tokens`:
    /// that field also counts invisible thinking tokens, which were never something the user had to read.
    let lastVisibleCharCount: Int?

    /// Total context tokens sent on the most recent turn — for Claude Code this is that turn's
    /// `cache_creation_input_tokens + cache_read_input_tokens` (the whole prefix resent that request);
    /// for Codex it's `totalInputTokens` straight off the latest `token_count` event. Deliberately a
    /// single-turn snapshot, not the session-lifetime `cacheCreationTokens`/`cacheReadTokens` sum below
    /// (those accumulate every turn's cache traffic and are meant for the cost/savings meter, not "how
    /// big is context right now"). Nil until at least one turn has usage data.
    let currentContextTokens: Int?

    /// Whether this session is currently idle, mid-turn, or mid-compaction — see SessionActivity and
    /// TranscriptWatcher.parseActivity for how this is inferred (there's no explicit "in progress" event
    /// in the transcript).
    let activity: SessionActivity
    /// When the open `/compact` was submitted, only set while `activity == .compacting` — lets the UI show
    /// how long compaction has been running. Nil otherwise (including once `compact_boundary` closes it).
    let compactionStartedAt: Date?

    /// TTL actually observed on this session's most recent cache-writing turn, read straight from the
    /// transcript's `usage.cache_creation.ephemeral_{1h,5m}_input_tokens` fields. When present this is
    /// ground truth for that turn, not a heuristic guess — see README "Deviations from spec.md".
    let detectedTTL: TimeInterval?

    /// Cold-cache rewrite events found in this transcript (see CacheExpiryEvent) — the input to the
    /// "lost to cache expirations today" meter. One entry per idle gap that let the cache go cold.
    var expiryEvents: [CacheExpiryEvent] = []

    /// Size, in characters, of the largest single `tool_result` still loaded in context (nothing has
    /// `/compact`ed or `/clear`ed it away since it landed) — the "big tool dump" signal. A huge inline
    /// tool result (a full file read, a big Bash dump) inflates every subsequent turn until it's compacted
    /// away. Nil when the transcript exposed no tool results. See TranscriptWatcher for how it's tracked and
    /// `Session.bigToolResultCharThreshold` for what counts as "big".
    var loadedToolResultChars: Int? = nil

    /// Name of the tool whose result is the `loadedToolResultChars` dump (e.g. "Bash", "Read"), matched
    /// via the transcript's `tool_use_id`. Nil if unknown (e.g. Codex, which doesn't track this yet) or if
    /// no big dump is loaded.
    var loadedToolResultToolName: String? = nil

    /// A tool result at or above this many characters (~10k tokens at ~4 chars/token) is treated as a
    /// "big dump" worth nudging the user to `/compact`. A named constant so it's easy to tune.
    static let bigToolResultCharThreshold = 40_000

    /// Whether a big, un-compacted tool result is currently sitting in this session's context. Detail-panel
    /// signal only — the row badge uses `hasBigContext` instead (see below), since a session can be over
    /// budget purely from many small turns accumulating with no single dump responsible.
    var hasBigToolDumpLoaded: Bool { (loadedToolResultChars ?? 0) >= Session.bigToolResultCharThreshold }

    /// Standard context window size in tokens. Transcripts never record which window a session is
    /// actually running with (e.g. whether 1M-context is active — see `extendedContextWindowTokens`),
    /// so this is the assumption used unless `currentContextTokens` itself proves it wrong.
    static let standardContextWindowTokens = 200_000

    /// The 1M-context tier. If a session's actual token count exceeds `standardContextWindowTokens`, the
    /// call could only have succeeded with this larger window active, so it's inferred rather than assumed.
    static let extendedContextWindowTokens = 1_000_000

    /// Absolute token count, not a fraction, at which the standard 200K window earns the "big context"
    /// badge — 75% of it, the point where reloading the whole prefix is already a meaningfully expensive
    /// turn.
    static let standardContextWarnTokens = 150_000

    /// Warn threshold for the 1M tier. Deliberately not the same 75% ratio as the standard tier (which
    /// would be 750K): 600K of resent context is already expensive to reload every turn regardless of
    /// how much headroom is left in a 1M window, so this is a flat, lower absolute threshold instead.
    static let extendedContextWarnTokens = 600_000

    /// The context window this session is actually running with — inferred, not assumed, whenever
    /// `currentContextTokens` alone proves the standard 200K window couldn't have fit it.
    var effectiveContextWindowTokens: Int {
        (currentContextTokens ?? 0) > Session.standardContextWindowTokens
            ? Session.extendedContextWindowTokens
            : Session.standardContextWindowTokens
    }

    /// How full the effective context window is right now, or nil if no usage data is available yet.
    /// Display-only (the tooltip's "X% of window" figure) — `hasBigContext` below uses an absolute
    /// per-tier threshold, not this ratio, to decide when to warn.
    var contextWindowUsageRatio: Double? {
        currentContextTokens.map { Double($0) / Double(effectiveContextWindowTokens) }
    }

    /// The token count, for this session's effective window, at or above which the row shows the "big
    /// context" badge.
    var bigContextWarnTokens: Int {
        effectiveContextWindowTokens == Session.extendedContextWindowTokens
            ? Session.extendedContextWarnTokens
            : Session.standardContextWarnTokens
    }

    /// Whether total context — regardless of what put it there — is large enough to warrant the row
    /// badge. Unlike `hasBigToolDumpLoaded`, this fires just as readily for many small turns as for one
    /// big dump, since either way it's the same per-turn cost multiplier.
    var hasBigContext: Bool { (currentContextTokens ?? 0) >= bigContextWarnTokens }

    var cost: Double?

    /// Per-project token-savings stats from `rtk gain` (see RTKService), joined by working directory —
    /// nil until RTKService's own probe confirms `rtk` is actually installed on this machine.
    var rtkStats: RTKStats? = nil

    /// PIDs of currently-running `claude` OS processes whose cwd matches this session's working
    /// directory, from ProcessMatcher. Empty doesn't necessarily mean "this exact session is dead" (we
    /// can't attribute a PID to a specific session UUID — Claude Code doesn't log its own PID to the
    /// transcript, confirmed by grepping real transcripts for "pid"), but it does mean "no live claude
    /// process was found in this directory at all", which is the honest signal spec.md's TTL-only "warm"
    /// status can't give: a session can be nominally warm by cache math while its process already exited.
    var livePIDs: [Int32] = []

    var isProcessRunning: Bool { !livePIDs.isEmpty }

    var supportsCacheCountdown: Bool { agentKind == .claudeCode }

    var codexThreadURL: URL? {
        guard agentKind == .codex else { return nil }
        return URL(string: "codex://threads/\(id)")
    }

    var projectName: String {
        (workingDirectory as NSString).lastPathComponent
    }

    /// The TTL used for this row's countdown: the detected TTL if we have one, else the user's setting.
    func effectiveTTL(fallback: TimeInterval) -> TimeInterval {
        detectedTTL ?? fallback
    }

    var cacheHitRatio: Double? {
        if agentKind == .codex {
            guard let totalInputTokens, totalInputTokens > 0 else { return nil }
            return Double(cachedInputTokens ?? 0) / Double(totalInputTokens)
        }
        let total = cacheCreationTokens + cacheReadTokens
        guard total > 0 else { return nil }
        return Double(cacheReadTokens) / Double(total)
    }

    func remaining(now: Date, ttl: TimeInterval) -> TimeInterval {
        lastTurnTime.addingTimeInterval(ttl).timeIntervalSince(now)
    }

    func status(now: Date, ttl: TimeInterval, expiringSoonThreshold: TimeInterval) -> CacheStatus {
        let r = remaining(now: now, ttl: ttl)
        if r <= 0 { return .cold }
        if r <= expiringSoonThreshold { return .expiringSoon }
        return .warm
    }
}
