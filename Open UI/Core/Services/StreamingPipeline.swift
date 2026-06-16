import Foundation
import os.log

private let pipelineLog = Logger(subsystem: "com.openui", category: "StreamingPipeline")

// MARK: - Streaming Snapshot (main-thread readable output)

/// Immutable snapshot published to the main thread every drain tick.
/// All fields are pre-computed and pre-sliced by the background actor —
/// the main thread reads them without doing any O(N) string work.
struct StreamingSnapshot: Sendable {
    /// Content currently visible to the user (typewriter-drained). Full string.
    let displayContent: String

    // MARK: - Tool/reasoning split-render pre-slices
    //
    // When frozenBoundary > 0, the pipeline slices displayContent into
    // frozenContent + liveTail off-main so the view reads them directly.
    // Both are "" when frozenBoundary == 0.

    /// Effective frozen boundary offset (max of tool and reasoning offsets).
    let frozenBoundary: Int
    /// displayContent[..<frozenBoundary] — stable tool/reasoning HTML. Empty when frozenBoundary==0.
    let frozenContent: String
    /// displayContent[frozenBoundary...] — tiny live tail changing each tick. Empty when frozenBoundary==0.
    let liveTail: String

    // MARK: - Prose split-render pre-slices (post-tool path)
    //
    // When frozenProseBoundaryOffset > frozenBoundary, liveTail is further split.

    /// Relative prose boundary within liveTail: (frozenProseBoundaryOffset - frozenBoundary). 0 if N/A.
    let relProseBoundary: Int
    /// liveTail[..<relProseBoundary] — settled paragraphs inside the live tail. Empty when N/A.
    let liveTailFrozenProse: String
    /// liveTail[relProseBoundary...] — current in-progress paragraph. Empty when N/A.
    let liveTailLiveProse: String

    // MARK: - Pure-prose split-render pre-slices (no tool/reasoning blocks)
    //
    // When frozenBoundary==0 and frozenProseBoundaryOffset>0, split displayContent directly.

    /// displayContent[..<frozenProseBoundaryOffset] — settled paragraphs. Empty when N/A.
    let pureFrozenProse: String
    /// displayContent[frozenProseBoundaryOffset...] — current in-progress paragraph. Empty when N/A.
    let pureLiveProse: String

    // MARK: - Offsets (for diagnostics / liveTail has-special-content checks)
    let frozenToolBoundaryOffset: Int
    let frozenReasoningBoundaryOffset: Int
    let frozenProseBoundaryOffset: Int

    /// True while the pipeline is actively running (including finishing drain).
    let isActive: Bool

    static let idle = StreamingSnapshot(
        displayContent: "",
        frozenBoundary: 0,
        frozenContent: "",
        liveTail: "",
        relProseBoundary: 0,
        liveTailFrozenProse: "",
        liveTailLiveProse: "",
        pureFrozenProse: "",
        pureLiveProse: "",
        frozenToolBoundaryOffset: 0,
        frozenReasoningBoundaryOffset: 0,
        frozenProseBoundaryOffset: 0,
        isActive: false
    )
}

// MARK: - StreamingPipeline Actor

/// Background actor that owns the streaming buffer, drain timer, and all
/// O(N) string analysis. The main thread **never** touches the raw string —
/// it only reads the pre-built `StreamingSnapshot` published here.
///
/// ## Threading model
/// - `append(_:)` / `finish()` / `abort()` — called from `@MainActor` callers
///   via `Task { await pipeline.xxx() }`, always off the main thread inside the actor.
/// - Internal drain timer fires on a dedicated background serial queue.
/// - `publishSnapshot()` hops to `@MainActor` to write the snapshot.
actor StreamingPipeline {

    // MARK: - Callback

    /// Called on `@MainActor` with every new snapshot.
    private let onSnapshot: @MainActor (StreamingSnapshot) -> Void

    init(onSnapshot: @escaping @MainActor (StreamingSnapshot) -> Void) {
        self.onSnapshot = onSnapshot
    }

    // MARK: - Buffer

    /// The full accumulated server content (ground truth, append-only).
    private var buffer: String = ""

    // MARK: - Display cursor

    /// How many characters of `buffer` have been revealed to the user.
    private var displayedCount: Int = 0

    // MARK: - Drain state

    private var drainAccumulator: Double = 0
    private var isFinishing: Bool = false

    // MARK: - Dynamic drain constants
    //
    // The typewriter reveals content so that displayed text lags behind the server
    // buffer by ~dynamicLatencyFrames. This adapts to model speed each tick:
    //
    //   • Slow model (few chars/frame arriving): higher latency → smooth trickle
    //   • Fast model (many chars/frame arriving): lower latency → near-instant reveal
    //
    // Because MarkdownView only receives the short live tail (not the full string),
    // there is no longer any rendering concern at high reveal rates. The goal is
    // simply to keep the typewriter effect perceptible while not making the user
    // wait for content that is already fully available on the server.

    /// Target drain latency in frames. At 60 Hz ≈ 133 ms of lag.
    /// Keeps a short but perceptible typewriter effect on fast models.
    private let targetLatencyFrames: Double = 8

    /// Shorter latency used once the server has finished sending.
    /// Drains any remaining buffer quickly so the user isn't waiting.
    private let finishingLatencyFrames: Double = 6

    /// Minimum chars/frame floor — ensures at least a trickle even with tiny buffers.
    private let minRatePerFrame: Double = 0.3

    /// Maximum chars/frame cap — 15 chars/frame × 60 Hz = 900 chars/sec,
    /// enough to reveal a fast model's output without visible lag.
    private let maxRatePerFrame: Double = 15.0

    /// Perceptual keep-back: reserve this many chars so the drain never fully
    /// empties the buffer mid-stream (avoids the "catch-up then pause" stutter).
    /// Disabled when isFinishing (we want to drain to zero).
    private let tailReserve: Int = 2

    // MARK: - Boundary cache (computed off-main, published via snapshot)

    private var frozenToolBoundaryOffset: Int = 0
    private var frozenReasoningBoundaryOffset: Int = 0
    private var frozenProseBoundaryOffset: Int = 0

    // MARK: - Stable-slice cache (preserves COW identity so downstream == is O(1))
    //
    // frozenContent / liveTailFrozenProse / pureFrozenProse only change when their
    // respective boundary offset advances. By storing the last computed String and
    // the offset it was built from, we hand the *same* String instance to the
    // snapshot when the boundary hasn't moved. Swift String == fast-paths to true
    // instantly when both sides share the same internal buffer (COW pointer equality),
    // so AssistantMessageContent.ParseCache skips its O(N) reparse on stable ticks.

    private var _cachedFrozenContent: (offset: Int, value: String) = (0, "")
    private var _cachedLiveTailFrozenProse: (offset: Int, value: String) = (0, "")
    private var _cachedPureFrozenProse: (offset: Int, value: String) = (0, "")

    // MARK: - Flags cache (keyed by buffer.utf8.count — O(1) after first calc)

    private struct ToolCallBlockFlags {
        let hasUnclosed: Bool
        let hasClosed: Bool
    }
    private var _toolCallFlagsCache: (contentCount: Int, flags: ToolCallBlockFlags)?
    private var _reasoningFlagsCache: (contentCount: Int, hasClosed: Bool)?
    /// Cached result of `hasOpenLivePreviewFence`, keyed by utf8.count.
    private var _livePreviewFenceCache: (contentCount: Int, hasOpen: Bool)?

    // MARK: - Drain timer

    private var drainTimer: DispatchSourceTimer?
    private static let timerQueue = DispatchQueue(
        label: "com.openui.StreamingPipeline.drain",
        qos: .userInteractive
    )

    // MARK: - Public interface (called from @MainActor)

    /// Begin a new streaming session. Resets all state and starts the drain timer.
    func begin() {
        resetState()
        startTimer()
    }

    /// Append new server content. Content is always the full accumulated string.
    func append(_ content: String) {
        guard !isFinishing else { return }
        buffer = content
    }

    /// Signal that the server has finished sending tokens.
    /// The timer keeps running to drain the remaining buffer, then stops.
    func finish() {
        isFinishing = true
    }

    /// Immediately flush and stop. Used for abort / error paths.
    func abort() -> String {
        let result = buffer
        stopTimer()
        resetState()
        Task { @MainActor [onSnapshot] in onSnapshot(.idle) }
        return result
    }

    // MARK: - Internal reset

    private func resetState() {
        buffer = ""
        displayedCount = 0
        drainAccumulator = 0
        isFinishing = false
        frozenToolBoundaryOffset = 0
        frozenReasoningBoundaryOffset = 0
        frozenProseBoundaryOffset = 0
        _toolCallFlagsCache = nil
        _reasoningFlagsCache = nil
        _livePreviewFenceCache = nil
        _cachedFrozenContent = (0, "")
        _cachedLiveTailFrozenProse = (0, "")
        _cachedPureFrozenProse = (0, "")
    }

    // MARK: - Timer management

    private func startTimer() {
        stopTimer()
        let timer = DispatchSource.makeTimerSource(queue: Self.timerQueue)
        // 60 Hz drain cadence — 16 ms interval. The scroll glide is handled by
        // .defaultScrollAnchor(.bottom) which pins sub-pixel continuously; the
        // drain timer only controls typewriter character reveal rate.
        timer.schedule(deadline: .now(), repeating: .milliseconds(16), leeway: .milliseconds(2))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            Task { await self.drainTick() }
        }
        timer.resume()
        drainTimer = timer
    }

    private func stopTimer() {
        drainTimer?.cancel()
        drainTimer = nil
    }

    // MARK: - Drain tick (runs inside actor isolation, off main thread)

    private func drainTick() {
        let full = buffer

        // Finish-exit: drain to zero when the server is done.
        if isFinishing && full.count == displayedCount {
            stopTimer()
            Task { @MainActor [onSnapshot] in onSnapshot(.idle) }
            return
        }

        // ── Tool call freeze ──────────────────────────────────────────────────
        // Hold the drain cursor while an unclosed tool_calls block is in-flight
        // so the user never sees partial HTML. Fall through when isFinishing so
        // content isn't left invisible if the server completes without closing.
        if toolCallFlags(for: full).hasUnclosed {
            if !isFinishing { return }
        }

        // ── Closed reasoning fast-forward ─────────────────────────────────────
        if hasClosedReasoningBlock(full) {
            if let lastEnd = Self.lastReasoningDetailsEnd(in: full), displayedCount < lastEnd {
                let endIdx = full.index(full.startIndex, offsetBy: lastEnd)
                displayedCount = lastEnd
                frozenReasoningBoundaryOffset = lastEnd
                drainAccumulator = 0
                publishSnapshot(displayContent: String(full[..<endIdx]))
                return
            }
        }

        // ── Closed tool call fast-forward ─────────────────────────────────────
        if toolCallFlags(for: full).hasClosed {
            if let lastEnd = Self.lastToolCallDetailsEnd(in: full), displayedCount < lastEnd {
                let endIdx = full.index(full.startIndex, offsetBy: lastEnd)
                displayedCount = lastEnd
                frozenToolBoundaryOffset = lastEnd
                drainAccumulator = 0
                publishSnapshot(displayContent: String(full[..<endIdx]))
                return
            }
        }

        // ── Target-latency drain ──────────────────────────────────────────────
        //
        // Drain formula: rate = buffered / targetLatencyFrames
        //
        // This keeps the typewriter ~133ms behind the server buffer on any model.
        // Fast models get a near-instant reveal; slow models get smooth trickle.
        // maxRatePerFrame prevents the drain from jumping too far in a single tick
        // on very large batches.
        //
        // Because MarkdownView only receives the short live tail (not the full
        // accumulated string), there is no rendering performance concern at high
        // reveal rates — the renderer handles the small delta cheaply.

        let fullCount = full.count   // O(N) — paid once, after all early-return branches
        let currentBuffered = fullCount - displayedCount

        // Keep-back: reserve a couple chars while streaming to prevent the cursor
        // catching up to zero and stalling when the server briefly pauses.
        let effectiveBuffered = isFinishing ? currentBuffered : max(0, currentBuffered - tailReserve)
        guard effectiveBuffered > 0 else { return }

        let latency = isFinishing ? finishingLatencyFrames : targetLatencyFrames
        let baseRate = Double(effectiveBuffered) / latency
        let charsThisFrame: Double

        // Live-preview code fences (html/svg/mermaid/chart) are rendered by a
        // WKWebView — fast-drain these so the WebView receives content quickly.
        if hasOpenLivePreviewFence(in: full) {
            charsThisFrame = max(baseRate, 500.0)
        } else {
            charsThisFrame = min(max(baseRate, minRatePerFrame), maxRatePerFrame)
        }

        drainAccumulator += charsThisFrame
        let reveal = min(Int(drainAccumulator), currentBuffered)
        guard reveal > 0 else { return }
        drainAccumulator -= Double(reveal)

        let newDisplayedCount = displayedCount + reveal
        let endIdx = full.index(full.startIndex, offsetBy: newDisplayedCount)
        displayedCount = newDisplayedCount
        let newDisplayContent = String(full[..<endIdx])

        // ── Paragraph boundary (prose freeze) ────────────────────────────────
        let effectiveFrozen = max(frozenToolBoundaryOffset, frozenReasoningBoundaryOffset)
        updateProseBoundary(in: newDisplayContent, effectiveFrozen: effectiveFrozen)

        publishSnapshot(displayContent: newDisplayContent)
    }

    // MARK: - Prose boundary helpers

    /// Minimum characters the live tail must grow beyond the current prose boundary
    /// before it advances. Larger value = fewer live→frozen migrations = fewer visible
    /// reflow/settle pops during streaming. 1200 chars ≈ ~3–5 paragraphs of prose.
    private static let proseBoundaryHysteresis: Int = 1200

    private func updateProseBoundary(in dc: String, effectiveFrozen: Int) {
        if effectiveFrozen > 0 {
            guard dc.count > effectiveFrozen else { return }
            let tailStartIdx = dc.index(dc.startIndex, offsetBy: effectiveFrozen)
            let relCandidate = Self.lastParagraphBoundary(in: String(dc[tailStartIdx...]))
            if relCandidate > 0 {
                let abs = effectiveFrozen + relCandidate
                if abs > frozenProseBoundaryOffset + Self.proseBoundaryHysteresis {
                    frozenProseBoundaryOffset = abs
                }
            }
        } else {
            let candidate = Self.lastParagraphBoundary(in: dc)
            if candidate > frozenProseBoundaryOffset + Self.proseBoundaryHysteresis {
                frozenProseBoundaryOffset = candidate
            }
        }
    }

    // MARK: - Publish (hops to @MainActor)

    /// Builds the snapshot with all pre-sliced strings (off-main), then delivers to @MainActor.
    private func publishSnapshot(displayContent: String) {
        let fb = max(frozenToolBoundaryOffset, frozenReasoningBoundaryOffset)
        let prose = frozenProseBoundaryOffset
        let dcCount = displayContent.count

        var frozenContent = ""
        var liveTail = ""
        var relProse = 0
        var liveTailFrozenProse = ""
        var liveTailLiveProse = ""
        var pureFrozenProse = ""
        var pureLiveProse = ""

        if fb > 0 && dcCount >= fb {
            // Tool/reasoning split — frozenContent is stable once fb stops advancing.
            // Cache the String value so downstream == is O(1) on stable ticks.
            //
            // NOTE: displayContent is a new String allocation every drain tick.
            // Never store or reuse a String.Index across ticks — always recompute fresh.
            let fbIdx = displayContent.index(displayContent.startIndex, offsetBy: fb)
            if _cachedFrozenContent.offset == fb {
                frozenContent = _cachedFrozenContent.value
            } else {
                frozenContent = String(displayContent[..<fbIdx])
                _cachedFrozenContent = (fb, frozenContent)
            }
            liveTail = String(displayContent[fbIdx...])

            // Further split liveTail at prose boundary.
            if prose > fb {
                let relP = prose - fb
                if liveTail.count >= relP {
                    let splitIdx = liveTail.index(liveTail.startIndex, offsetBy: relP)
                    if _cachedLiveTailFrozenProse.offset == prose {
                        liveTailFrozenProse = _cachedLiveTailFrozenProse.value
                    } else {
                        liveTailFrozenProse = String(liveTail[..<splitIdx])
                        _cachedLiveTailFrozenProse = (prose, liveTailFrozenProse)
                    }
                    liveTailLiveProse = String(liveTail[splitIdx...])
                    relProse = relP
                }
            }
        } else if fb == 0 && prose > 0 && dcCount >= prose {
            // Pure-prose split (no tool/reasoning blocks).
            let splitIdx = displayContent.index(displayContent.startIndex, offsetBy: prose)
            if _cachedPureFrozenProse.offset == prose {
                pureFrozenProse = _cachedPureFrozenProse.value
            } else {
                pureFrozenProse = String(displayContent[..<splitIdx])
                _cachedPureFrozenProse = (prose, pureFrozenProse)
            }
            pureLiveProse = String(displayContent[splitIdx...])
        }

        let snap = StreamingSnapshot(
            displayContent: displayContent,
            frozenBoundary: fb,
            frozenContent: frozenContent,
            liveTail: liveTail,
            relProseBoundary: relProse,
            liveTailFrozenProse: liveTailFrozenProse,
            liveTailLiveProse: liveTailLiveProse,
            pureFrozenProse: pureFrozenProse,
            pureLiveProse: pureLiveProse,
            frozenToolBoundaryOffset: frozenToolBoundaryOffset,
            frozenReasoningBoundaryOffset: frozenReasoningBoundaryOffset,
            frozenProseBoundaryOffset: frozenProseBoundaryOffset,
            isActive: true
        )
        Task { @MainActor [onSnapshot] in onSnapshot(snap) }
    }

    // MARK: - Live-preview fence detection (all off-main)

    /// Returns `true` when `content` contains an unclosed live-preview code fence
    /// (` ```html `, ` ```svg `, ` ```mermaid `, ` ```chart* `).
    /// Result is cached by utf8.count — O(1) on repeat calls for the same buffer length.
    private func hasOpenLivePreviewFence(in content: String) -> Bool {
        let count = content.utf8.count
        if let cached = _livePreviewFenceCache, cached.contentCount == count {
            return cached.hasOpen
        }
        let fences = ["```html\n", "```svg\n", "```mermaid\n",
                      "```chart\n", "```chartjs\n", "```echarts\n",
                      "```highcharts\n", "```plotly\n",
                      "```vega-lite\n", "```vegalite\n"]
        var result = false
        let lower = content.lowercased()
        for fence in fences {
            guard let openRange = lower.range(of: fence) else { continue }
            if lower[openRange.upperBound...].range(of: "\n```") == nil {
                result = true
                break
            }
        }
        // VIZ blocks (@@@VIZ-START…@@@VIZ-END) are large HTML payloads — fast-drain.
        if !result && content.contains("@@@VIZ-START") && !content.contains("\n@@@VIZ-END") {
            result = true
        }
        _livePreviewFenceCache = (count, result)
        return result
    }

    // MARK: - Details block detection (all off-main)

    private func toolCallFlags(for content: String) -> ToolCallBlockFlags {
        let count = content.utf8.count
        if let cached = _toolCallFlagsCache, cached.contentCount == count {
            return cached.flags
        }

        guard content.contains("tool_calls") else {
            let flags = ToolCallBlockFlags(hasUnclosed: false, hasClosed: false)
            _toolCallFlagsCache = (count, flags)
            return flags
        }

        var toolCallOpenCount = 0
        var totalCloseCount = 0
        var reasoningOpenCount = 0

        var idx = content.startIndex
        while idx < content.endIndex {
            if content[idx] == "<" {
                let detailsTag = "<details"
                if content[idx...].hasPrefix(detailsTag) {
                    let afterDetails = content.index(idx, offsetBy: detailsTag.count, limitedBy: content.endIndex) ?? content.endIndex
                    var tagEnd = afterDetails
                    while tagEnd < content.endIndex && content[tagEnd] != ">" {
                        tagEnd = content.index(after: tagEnd)
                    }
                    let tagContent = String(content[idx..<tagEnd]).lowercased()
                    if tagContent.contains("tool_calls") {
                        toolCallOpenCount += 1
                    } else if tagContent.contains("type=\"reasoning\"") || tagContent.contains("type='reasoning'") {
                        reasoningOpenCount += 1
                    }
                    idx = tagEnd < content.endIndex ? content.index(after: tagEnd) : content.endIndex
                    continue
                }
                let closeTag = "</details>"
                if content[idx...].hasPrefix(closeTag) {
                    totalCloseCount += 1
                    idx = content.index(idx, offsetBy: closeTag.count, limitedBy: content.endIndex) ?? content.endIndex
                    continue
                }
            }
            idx = content.index(after: idx)
        }

        let toolCallCloseCount = max(0, totalCloseCount - reasoningOpenCount)
        let hasUnclosed = toolCallOpenCount > toolCallCloseCount
        let hasClosed = toolCallOpenCount > 0 && !hasUnclosed
        let flags = ToolCallBlockFlags(hasUnclosed: hasUnclosed, hasClosed: hasClosed)
        _toolCallFlagsCache = (count, flags)
        return flags
    }

    private func hasClosedReasoningBlock(_ content: String) -> Bool {
        let count = content.utf8.count
        if let cached = _reasoningFlagsCache, cached.contentCount == count {
            return cached.hasClosed
        }
        guard content.contains("reasoning"), content.contains("</details>") else {
            _reasoningFlagsCache = (count, false)
            return false
        }

        var reasoningOpenCount = 0
        var totalCloseCount = 0
        var idx = content.startIndex
        while idx < content.endIndex {
            if content[idx] == "<" {
                let detailsTag = "<details"
                if content[idx...].hasPrefix(detailsTag) {
                    let afterDetails = content.index(idx, offsetBy: detailsTag.count, limitedBy: content.endIndex) ?? content.endIndex
                    var tagEnd = afterDetails
                    while tagEnd < content.endIndex && content[tagEnd] != ">" {
                        tagEnd = content.index(after: tagEnd)
                    }
                    let tagContent = String(content[idx..<tagEnd]).lowercased()
                    if tagContent.contains("reasoning") { reasoningOpenCount += 1 }
                    idx = tagEnd < content.endIndex ? content.index(after: tagEnd) : content.endIndex
                    continue
                }
                let closeTag = "</details>"
                if content[idx...].hasPrefix(closeTag) {
                    totalCloseCount += 1
                    idx = content.index(idx, offsetBy: closeTag.count, limitedBy: content.endIndex) ?? content.endIndex
                    continue
                }
            }
            idx = content.index(after: idx)
        }
        let hasClosed = reasoningOpenCount > 0 && totalCloseCount >= reasoningOpenCount
        _reasoningFlagsCache = (count, hasClosed)
        return hasClosed
    }

    private static func lastReasoningDetailsEnd(in content: String) -> Int? {
        let closeTag = "</details>"
        guard content.contains("reasoning"), content.contains(closeTag) else { return nil }
        var closeEnds: [String.Index] = []
        var sr = content.startIndex..<content.endIndex
        while let r = content.range(of: closeTag, options: .caseInsensitive, range: sr) {
            closeEnds.append(r.upperBound); sr = r.upperBound..<content.endIndex
        }
        var openStarts: [String.Index] = []
        sr = content.startIndex..<content.endIndex
        while let r = content.range(of: "<details", options: .caseInsensitive, range: sr) {
            openStarts.append(r.lowerBound); sr = r.upperBound..<content.endIndex
        }
        guard !closeEnds.isEmpty && !openStarts.isEmpty else { return nil }
        var lastEnd: String.Index? = nil
        let pairCount = min(closeEnds.count, openStarts.count)
        for i in 0..<pairCount {
            if let tagEnd = content.range(of: ">", range: openStarts[i]..<content.endIndex) {
                let tagText = String(content[openStarts[i]..<tagEnd.upperBound]).lowercased()
                if tagText.contains("reasoning") { lastEnd = closeEnds[i] }
            }
        }
        guard let e = lastEnd else { return nil }
        return content.distance(from: content.startIndex, to: e)
    }

    private static func lastToolCallDetailsEnd(in content: String) -> Int? {
        let closeTag = "</details>"
        guard content.contains("tool_calls"), content.contains(closeTag) else { return nil }
        var closeEnds: [String.Index] = []
        var sr = content.startIndex..<content.endIndex
        while let r = content.range(of: closeTag, options: .caseInsensitive, range: sr) {
            closeEnds.append(r.upperBound); sr = r.upperBound..<content.endIndex
        }
        var openStarts: [String.Index] = []
        sr = content.startIndex..<content.endIndex
        while let r = content.range(of: "<details", options: .caseInsensitive, range: sr) {
            openStarts.append(r.lowerBound); sr = r.upperBound..<content.endIndex
        }
        guard !closeEnds.isEmpty && !openStarts.isEmpty else { return nil }
        var lastToolCallEnd: String.Index? = nil
        let pairCount = min(closeEnds.count, openStarts.count)
        for i in 0..<pairCount {
            if let tagEnd = content.range(of: ">", range: openStarts[i]..<content.endIndex) {
                let tagText = String(content[openStarts[i]..<tagEnd.upperBound]).lowercased()
                if tagText.contains("tool_calls") { lastToolCallEnd = closeEnds[i] }
            }
        }
        guard let e = lastToolCallEnd else { return nil }
        return content.distance(from: content.startIndex, to: e)
    }

    static func lastParagraphBoundary(in text: String, minTailLength: Int = 200) -> Int {
        let minLength = minTailLength + 100
        guard text.count > minLength else { return 0 }
        let safeEndIdx = text.index(text.endIndex, offsetBy: -minTailLength)
        let searchArea = text[text.startIndex..<safeEndIdx]
        guard let lastBlankLine = searchArea.range(of: "\n\n", options: .backwards) else { return 0 }
        let boundaryIdx = lastBlankLine.upperBound
        let textBefore = text[..<boundaryIdx]
        var fenceCount = 0
        var cur = textBefore.startIndex
        while let r = textBefore.range(of: "```", range: cur..<textBefore.endIndex) {
            fenceCount += 1; cur = r.upperBound
        }
        guard fenceCount % 2 == 0 else { return 0 }
        // Don't freeze a boundary inside an open VIZ block — the marker must stay
        // together in pureLiveProse so InlineVisualizerView can detect it.
        let hasUnclosedViz = textBefore.contains("@@@VIZ-START") && !textBefore.contains("\n@@@VIZ-END")
        guard !hasUnclosedViz else { return 0 }
        return text.distance(from: text.startIndex, to: boundaryIdx)
    }
}
