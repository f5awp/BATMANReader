// OptimalMatcher.swift
// The "optimal" reciprocal-package tier: provably FEWEST counterparties that can
// cover all your give-days with a BALANCED day-for-day swap, using min-cost flow
// for the assignment and a bounded branch-and-bound over counterparty subsets for
// the fewest-people objective (the part plain flow can't express). Falls back to
// the greedy heuristic for large instances (caller decides).

import Foundation

enum OptimalMatcher {

    struct Cand {
        let id: String
        let name: String
        let canTake: Set<String>   // my give-days this peer can cover
        let givesBack: [String]    // their days I can take back (balance capacity)
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

    /// Minimum-counterparty balanced reciprocal cover, or nil if infeasible / too
    /// large (use greedy then). `contiguous` validates the per-person SET so a
    /// package can't fragment anyone's break (the constraint pure flow can't
    /// express); default accepts everything.
    static func minPeopleReciprocal(giveDayIDs: [String], peers: [Cand],
                                    contiguous: ([Assignment]) -> Bool = { _ in true }) -> [Assignment]? {
        let days = Array(Set(giveDayIDs)).sorted()                 // deterministic
        guard !days.isEmpty, days.count <= maxDays, peers.count <= maxPeers else { return nil }
        // Only peers that can take a give-day and give something back; stable order.
        let usable = peers.filter { !$0.canTake.isDisjoint(with: days) && !$0.givesBack.isEmpty }
            .sorted { $0.id < $1.id }
        guard !usable.isEmpty else { return nil }

        let maxK = min(maxSubsetSize, usable.count, days.count)
        for k in 1...maxK {
            var best: [Assignment]?
            combinations(usable.count, k) { idxs in
                let subset = idxs.map { usable[$0] }
                if let a = feasibleAssignment(days: days, subset: subset), contiguous(a) {
                    best = a; return false
                }
                return true   // keep searching this size
            }
            if let best { return best }   // first feasible size = fewest people
        }
        return nil
    }

    // MARK: - Feasibility + assignment via min-cost flow (unit bipartite b-matching)

    private static func feasibleAssignment(days: [String], subset: [Cand]) -> [Assignment]? {
        let g = days.count, p = subset.count
        let source = 0
        let dayNode = { (i: Int) in 1 + i }
        let peerNode = { (j: Int) in 1 + g + j }
        let sink = 1 + g + p
        var mcf = MinCostFlow(nodes: sink + 1)

        for i in 0..<g { mcf.addEdge(source, dayNode(i), cap: 1, cost: 0) }
        for (j, c) in subset.enumerated() {
            for i in 0..<g where c.canTake.contains(days[i]) {
                mcf.addEdge(dayNode(i), peerNode(j), cap: 1, cost: 0)
            }
            mcf.addEdge(peerNode(j), sink, cap: c.givesBack.count, cost: 0)
        }
        let (flow, _) = mcf.run(from: source, to: sink)
        guard flow == g else { return nil }   // not every give-day covered

        // Read the assignment: each give-day → the peer whose edge it saturated.
        var byPeer = [Int: [String]]()   // peer index → my give-days they take
        for i in 0..<g {
            for target in mcf.saturatedTargets(from: dayNode(i)) {
                let j = target - (1 + g)
                if j >= 0 && j < p { byPeer[j, default: []].append(days[i]); break }
            }
        }

        // Balance: each peer takes back as many distinct days as they took of mine.
        var usedBack = Set<String>()
        var result: [Assignment] = []
        for (j, gives) in byPeer where !gives.isEmpty {
            let backs = subset[j].givesBack.filter { !usedBack.contains($0) }
            guard backs.count >= gives.count else { return nil }
            let takes = Array(backs.prefix(gives.count))
            usedBack.formUnion(takes)
            result.append(Assignment(id: subset[j].id, name: subset[j].name,
                                     giveDayIDs: gives, takeDayIDs: takes))
        }
        return result.isEmpty ? nil : result
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
