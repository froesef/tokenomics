import Foundation

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

/// One Claude Code session: one transcript file, one working directory, one independent prompt-cache
/// TTL timer (the cache is scoped per working directory — see spec.md §0).
struct Session: Identifiable, Equatable, Sendable {
    let id: String
    let workingDirectory: String
    /// Claude Code's own AI-generated summary of what the session is doing (from the transcript's
    /// `ai-title` event) — the same short label it uses as the Ghostty tab title. Nil until Claude Code
    /// has generated one, which usually happens after the first exchange.
    let aiTitle: String?
    let lastTurnTime: Date
    let cacheCreationTokens: Int
    let cacheReadTokens: Int
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

    var projectName: String {
        (workingDirectory as NSString).lastPathComponent
    }

    /// The TTL used for this row's countdown: the detected TTL if we have one, else the user's setting.
    func effectiveTTL(fallback: TimeInterval) -> TimeInterval {
        detectedTTL ?? fallback
    }

    var cacheHitRatio: Double? {
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
