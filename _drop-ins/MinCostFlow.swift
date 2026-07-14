// MinCostFlow.swift
// A general min-cost max-flow solver (successive shortest paths with SPFA, so it
// handles negative edge costs). Used by the optimal reciprocal matcher to verify
// balanced assignments and to minimize cost. Pure value type, fully testable.
//
// U-OBJ: forward edges are now tagged STRUCTURALLY at insertion. The old
// `saturatedTargets` identified forward edges by `cost >= 0`, which was only
// correct while every edge cost was 0; with real acceptance costs (−K·log p ≥ 0
// forward, ≤ 0 reverse) the sign test is one rounding case away from ambiguity,
// so the tag replaces it outright.

import Foundation

struct MinCostFlow {
    private struct Edge { var to: Int; var cap: Int; let cost: Int; let rev: Int; let forward: Bool }
    private var graph: [[Edge]]

    init(nodes: Int) { graph = Array(repeating: [], count: nodes) }

    /// Directed edge `from → to` with capacity and per-unit cost (residual added).
    mutating func addEdge(_ from: Int, _ to: Int, cap: Int, cost: Int) {
        graph[from].append(Edge(to: to, cap: cap, cost: cost, rev: graph[to].count, forward: true))
        graph[to].append(Edge(to: from, cap: 0, cost: -cost, rev: graph[from].count - 1, forward: false))
    }

    /// Push max flow at minimum cost from `s` to `t`. Returns (flow, cost).
    mutating func run(from s: Int, to t: Int) -> (flow: Int, cost: Int) {
        let n = graph.count
        var totalFlow = 0, totalCost = 0
        while true {
            var dist = Array(repeating: Int.max, count: n)
            var inQ  = Array(repeating: false, count: n)
            var prevV = Array(repeating: -1, count: n)
            var prevE = Array(repeating: -1, count: n)
            dist[s] = 0
            var queue = [s]; inQ[s] = true; var qi = 0
            while qi < queue.count {
                let v = queue[qi]; qi += 1; inQ[v] = false
                guard dist[v] != Int.max else { continue }
                for (i, e) in graph[v].enumerated() where e.cap > 0 && dist[v] + e.cost < dist[e.to] {
                    dist[e.to] = dist[v] + e.cost
                    prevV[e.to] = v; prevE[e.to] = i
                    if !inQ[e.to] { inQ[e.to] = true; queue.append(e.to) }
                }
            }
            if dist[t] == Int.max { break }                 // no more augmenting paths
            var f = Int.max, v = t
            while v != s { f = min(f, graph[prevV[v]][prevE[v]].cap); v = prevV[v] }
            v = t
            while v != s {
                graph[prevV[v]][prevE[v]].cap -= f
                let r = graph[prevV[v]][prevE[v]].rev
                graph[v][r].cap += f
                v = prevV[v]
            }
            totalFlow += f
            totalCost += f * dist[t]
        }
        return (totalFlow, totalCost)
    }

    /// After `run`, which `to`-nodes received flow from each `from`-node in a unit
    /// bipartite graph (FORWARD edge fully saturated). Forward edges are identified
    /// by the structural tag set in `addEdge`, never by cost sign — correct for any
    /// mix of zero, positive, and (if ever needed) negative edge costs.
    func saturatedTargets(from: Int) -> [Int] {
        graph[from].filter { $0.forward && $0.cap == 0 && $0.to != from }.map(\.to)
    }
}
