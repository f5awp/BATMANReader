// OptimalMatcher.swift
// The "optimal" reciprocal-package tier. U-OBJ rewrite:
//
//   • BOTH directions of the swap live in ONE flow —
//       source →(1,0) giveDay →(1, takeCost) peer →(1, backCost) backDay →(1,0) sink
//     Peer nodes have no source/sink edge, so flow conservation FORCES days-taken ==
//     days-given-back: balanced reciprocity is a graph invariant, not a post-hoc
//     prefix check. Back-days are GLOBAL unit nodes (you can only receive one shift
//     per calendar date, even from different peers).
//   • Edge costs are real: cost = round(−1000·ln legProb) ≥ 0, so max-flow-min-cost
//     returns the MAX-ACCEPTANCE balanced cover within a subset — the flow finally
//     optimizes the same objective the ranker sorts by. All costs are non-negative
//     (σ keeps legProb < 1), so SPFA never sees a negative forward edge.
//   • Branch-and-bound over subset SIZE is kept for the fewest-people search, but a
//     size class is now scanned EXHAUSTIVELY for its min-cost member (the old code
//     stopped at the first feasible subset — feasibility-blind to acceptance). The
//     fewest size k* is returned first (flagged optimal by the caller), and the best
//     (k*+1)-subset rides along as an alternative — the unified score decides.
//
// Falls back to the greedy heuristic for large instances (caller decides).

import Foundation

enum OptimalMatcher {

    struct Cand {
        let id: String
        let name: String
        let canTake: Set<String>   // my give-days this peer can cover
        let givesBack: [String]    // their days I can take back (balance capacity)
        /// Acceptance cost of the FORWARD leg (my give-day → this peer), per day.
        /// −round(1000·ln legProb); a missing day costs 0 (acceptance-blind, which
        /// reproduces the old all-costs-zero behavior — existing tests stay valid).
        var takeCost: [String: Int] = [:]
        /// Acceptance cost of the RETURN leg (this peer's day → me), per day.
        var backCost: [String: Int] = [:]

        init(id: String, name: String, canTake: Set<String>, givesBack: [String],
             takeCost: [String: Int] = [:], backCost: [String: Int] = [:]) {
            self.id = id; self.name = name; self.canTake = canTake; self.givesBack = givesBack
            self.takeCost = takeCost; self.backCost = backCost
        }
    }

    struct Assignment {
        let id: String
        let name: String
        let giveDayIDs: [String]   // my shifts they take
        let takeDayIDs: [String]   // their shifts I take back
    }

    // Bounds so this stays instant on-device; beyond these the caller uses greedy.
    static let maxPeers = 16
    static let maxDays = 10
    static let maxSubsetSize = 5

    /// Cost scale for −ln legProb (millinats). σ bounds legProb below ~0.9934 for
    /// non-ECB legs, so every real leg costs ≥ ~7 — forward costs are never negative.
    static let costScale = 1000.0

    /// Integer edge cost for a leg with acceptance probability `prob`.
    static func legCost(prob: Double) -> Int {
        guard prob > 0 else { return Int(costScale * 16) }        // p→0: effectively forbidden
        return max(0, Int((-log(min(prob, 1.0)) * costScale).rounded()))
    }

    /// Up to TWO best-acceptance balanced reciprocal covers:
    ///   [0] the min-cost assignment at the FEWEST feasible people-count k* (the caller
    ///       flags this `isOptimal` — "provably fewest" is preserved), and
    ///   [1] when feasible, the min-cost assignment at k*+1 — a bigger-but-maybe-cleaner
    ///       alternative. The unified ranker decides between them; nothing is hidden.
    /// Empty when infeasible / out of bounds (the caller falls back to greedy).
    /// `contiguous` validates the per-person SET so a package can't fragment anyone's
    /// break (the constraint pure flow can't express); default accepts everything.
    static func reciprocalOptions(giveDayIDs: [String], peers: [Cand],
                                  contiguous: ([Assignment]) -> Bool = { _ in true }) -> [[Assignment]] {
        let days = Array(Set(giveDayIDs)).sorted()                 // deterministic
        guard !days.isEmpty, days.count <= maxDays, peers.count <= maxPeers else { return [] }
        // Only peers that can take a give-day and give something back; stable order.
        let usable = peers.filter { !$0.canTake.isDisjoint(with: days) && !$0.givesBack.isEmpty }
            .sorted { $0.id < $1.id }
        guard !usable.isEmpty else { return [] }

        let maxK = min(maxSubsetSize, usable.count, days.count)
        var options: [[Assignment]] = []
        var k = 1
        while k <= maxK, options.count < 2, !Task.isCancelled {
            if let best = bestAssignment(days: days, usable: usable, k: k, contiguous: contiguous) {
                options.append(best)                     // k* first, then k*+1
            } else if !options.isEmpty {
                break                                    // k*+1 infeasible — only k* exists
            }
            k += 1
        }
        return options
    }

    /// COMPAT — the old single-result API: the fewest-people cover, now the
    /// max-acceptance one within that people-count (min total edge cost at k*).
    static func minPeopleReciprocal(giveDayIDs: [String], peers: [Cand],
                                    contiguous: ([Assignment]) -> Bool = { _ in true }) -> [Assignment]? {
        reciprocalOptions(giveDayIDs: giveDayIDs, peers: peers, contiguous: contiguous).first
    }

    // MARK: - Best (min-cost) feasible assignment within one subset-size class

    private static func bestAssignment(days: [String], usable: [Cand], k: Int,
                                       contiguous: ([Assignment]) -> Bool) -> [Assignment]? {
        var best: [Assignment]?
        var bestCost = Int.max
        combinations(usable.count, k) { idxs in
            if Task.isCancelled { return false }         // cooperative cancel mid-scan
            let subset = idxs.map { usable[$0] }
            if let (a, cost) = flowAssignment(days: days, subset: subset),
               cost < bestCost, contiguous(a) {
                best = a; bestCost = cost
            }
            return true   // exhaust the whole size class — we want the BEST of k, not the first
        }
        return best
    }

    // MARK: - Feasibility + max-acceptance assignment via one min-cost flow

    /// Both swap directions in one graph. Feasible iff maxflow == day count; the
    /// min-cost flow then maximizes Σ ln legProb across FORWARD AND RETURN legs.
    /// Returns nil when the subset can't cover every give-day with balance.
    private static func flowAssignment(days: [String], subset: [Cand]) -> ([Assignment], Int)? {
        let g = days.count, p = subset.count
        // Global back-day universe: one node per calendar date across ALL peers, cap 1
        // to sink — I can't receive two shifts on the same date.
        var backDays: [String] = []
        var backIndex: [String: Int] = [:]
        for c in subset {
            for d in c.givesBack where backIndex[d] == nil {
                backIndex[d] = backDays.count; backDays.append(d)
            }
        }
        let source = 0
        let dayNode  = { (i: Int) in 1 + i }
        let peerNode = { (j: Int) in 1 + g + j }
        let backNode = { (b: Int) in 1 + g + p + b }
        let sink = 1 + g + p + backDays.count
        var mcf = MinCostFlow(nodes: sink + 1)

        for i in 0..<g { mcf.addEdge(source, dayNode(i), cap: 1, cost: 0) }
        for (j, c) in subset.enumerated() {
            for i in 0..<g where c.canTake.contains(days[i]) {
                mcf.addEdge(dayNode(i), peerNode(j), cap: 1, cost: c.takeCost[days[i]] ?? 0)
            }
            for d in c.givesBack {
                mcf.addEdge(peerNode(j), backNode(backIndex[d]!), cap: 1, cost: c.backCost[d] ?? 0)
            }
        }
        for b in 0..<backDays.count { mcf.addEdge(backNode(b), sink, cap: 1, cost: 0) }

        let (flow, cost) = mcf.run(from: source, to: sink)
        guard flow == g else { return nil }   // not every give-day covered (with balance)

        // Read the assignment from saturated FORWARD unit edges.
        var gives = [Int: [String]]()   // peer index → my give-days they take
        var takes = [Int: [String]]()   // peer index → their days I take back
        for i in 0..<g {
            for target in mcf.saturatedTargets(from: dayNode(i)) {
                let j = target - (1 + g)
                if j >= 0 && j < p { gives[j, default: []].append(days[i]); break }
            }
        }
        for j in 0..<p {
            for target in mcf.saturatedTargets(from: peerNode(j)) {
                let b = target - (1 + g + p)
                if b >= 0 && b < backDays.count { takes[j, default: []].append(backDays[b]) }
            }
        }

        var result: [Assignment] = []
        for j in 0..<p {
            let gv = gives[j] ?? []
            guard !gv.isEmpty else { continue }
            let tk = takes[j] ?? []
            guard tk.count == gv.count else { return nil }   // conservation guarantees this; belt & braces
            result.append(Assignment(id: subset[j].id, name: subset[j].name,
                                     giveDayIDs: gv, takeDayIDs: tk))
        }
        return result.isEmpty ? nil : (result, cost)
    }

    // MARK: - Bounded combination generator (stops when `body` returns false)

    private static func combinations(_ n: Int, _ k: Int, _ body: ([Int]) -> Bool) {
        var idx = Array(0..<k)
        guard k <= n else { return }
        while true {
            if !body(idx) { return }
            var i = k - 1
            while i >= 0 && idx[i] == n - k + i { i -= 1 }
            if i < 0 { return }
            idx[i] += 1
            for j in (i + 1)..<k { idx[j] = idx[j - 1] + 1 }
        }
    }
}
