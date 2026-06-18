#!/usr/bin/env bash
# Guard: keeps ARCHITECTURE_MAP.md from rotting. Enforces that the map's
# REFERENCES resolve — it cannot (and does not claim to) verify that prose
# descriptions are accurate.
#
# Checks:
#   1. Every *.swift filename named in the map exists in the repo.
#   2. Every spec ID (S-XXX-N / U-XXX-N) cited in the map exists in the spec docs.
#   3. Curated "single source of truth" symbols still exist in source.
#
# Run manually (part of Definition of Done):  bash scripts/check_arch_map.sh
# Override the map for red/green demos:        MAP=/tmp/x.md bash scripts/check_arch_map.sh
set -uo pipefail
cd "$(dirname "$0")/.."

MAP="${MAP:-Documentation/ARCHITECTURE_MAP.md}"
SPECS=(Documentation/SPEC_STRUCTURAL.md Documentation/SPEC_UIUX.md)
errors=0

# 1) Swift filenames referenced in the map must exist somewhere in the repo.
while IFS= read -r f; do
  [ -z "$f" ] && continue
  if ! find . -name "$f" -not -path '*/.git/*' | grep -q .; then
    echo "❌ map names a missing file: $f"; errors=$((errors+1))
  fi
done < <(grep -oE '[A-Za-z0-9_]+\.swift' "$MAP" | sort -u)

# 2) Spec IDs cited in the map must exist in the spec docs.
while IFS= read -r id; do
  [ -z "$id" ] && continue
  if ! grep -qE "$id" "${SPECS[@]}"; then
    echo "❌ map cites an unknown spec ID: $id"; errors=$((errors+1))
  fi
done < <(grep -oE '\b[SU]-[A-Z]+-[0-9]+\b' "$MAP" | sort -u)

# 3) Curated single-source-of-truth symbols must still resolve in source.
SOT_SYMBOLS=(
  "func reconcileTargets"
  "func reconcile(diff:"
  "func parseAllWorkers"
  "func minPeopleReciprocal"
  "enum TradeRequestStatus"
  "func runAll"
  "func tradeTypeLabel"
  "func distinctParticipants"
)
for sym in "${SOT_SYMBOLS[@]}"; do
  if ! grep -rqF "$sym" --include='*.swift' .; then
    echo "❌ SOT symbol not found in source: $sym"; errors=$((errors+1))
  fi
done

# 4) Convention scan (S-TEST-1): trade-type labels must come ONLY from tradeTypeLabel().
#    No stray interpolated "-way trade" / "-person swap" / "-person trade" literals.
strays="$(grep -rnE '\)-way trade|\)-person (swap|trade)|[0-9]-person (swap|trade)|Individual taker' --include='*.swift' . || true)"
if [ -n "$strays" ]; then
  echo "❌ stray trade-type label literal(s) outside tradeTypeLabel():"
  echo "$strays" | sed 's/^/   /'
  errors=$((errors+1))
fi

if [ "$errors" -eq 0 ]; then
  echo "✅ arch-map guard passed"
else
  echo "FAILED: $errors reference(s) in ARCHITECTURE_MAP.md no longer resolve."
  exit 1
fi
