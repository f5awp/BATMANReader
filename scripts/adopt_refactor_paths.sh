#!/bin/bash
#
# adopt_refactor_paths.sh
# ------------------------
# The domain-driven refactor (PR #1) physically moved every source file into
# Sources/… but did NOT update the Xcode project, which still references each
# file by its old ROOT path (e.g. `path = TradeMatcher.swift;`). That's why
# nothing compiles after the merge.
#
# This rewrites each explicit PBXFileReference path in project.pbxproj to the
# file's NEW location under Sources/ (derived live from `git ls-files`, so it
# always matches what's actually on disk), and fixes the widget entitlements
# path. Logic is untouched — only project file-reference paths change.
#
# ⚠️  RUN ON THE `main` BRANCH WITH XCODE FULLY QUIT (⌘Q). Editing the project
#     file while Xcode is open can corrupt it.
#
# Undo at any time:  mv "$PBX.bak" "$PBX"   (or: git checkout -- "$PBX")
#
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT"
PBX="BATMANReader.xcodeproj/project.pbxproj"

[ -f "$PBX" ] || { echo "ERROR: $PBX not found"; exit 1; }
[ -d "Sources" ] || { echo "ERROR: no Sources/ dir — are you on the refactored 'main' branch?"; exit 1; }
git diff --quiet -- "$PBX" || { echo "ERROR: $PBX already has uncommitted edits. Run 'git checkout -- $PBX' first, then re-run."; exit 1; }

cp "$PBX" "$PBX.bak"   # safety backup

changed=0
# Every file that now lives under Sources/ — rewrite its file-reference path.
# Anchoring on '; sourceTree' guarantees we only touch PBXFileReference lines,
# never build settings or comments.
while IFS= read -r newpath; do
  base="$(basename "$newpath")"
  if grep -q "path = $base; sourceTree" "$PBX"; then
    perl -0pi -e "s{path = \Q$base\E; sourceTree}{path = $newpath; sourceTree}g" "$PBX"
    changed=$((changed + 1))
  fi
done < <(git ls-files Sources)

# Widget extension entitlements moved to Sources/Support/ — fix the build setting.
perl -0pi -e 's{CODE_SIGN_ENTITLEMENTS = BATMANWidgetsExtension\.entitlements;}{CODE_SIGN_ENTITLEMENTS = Sources/Support/BATMANWidgetsExtension.entitlements;}g' "$PBX"

echo "✅ Rewrote $changed source reference(s) + entitlements path."
echo "   Backup: $PBX.bak"
echo "   Next: open Xcode, Product ▸ Clean Build Folder (⇧⌘K), then build."
echo "   If anything looks wrong: mv \"$PBX.bak\" \"$PBX\"   (or git checkout -- \"$PBX\")"
