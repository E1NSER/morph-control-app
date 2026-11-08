#!/bin/bash
set -euo pipefail

project_dir="$(cd "$(dirname "$0")/.." && pwd)"
scratch_path="${1:-$project_dir/work/demo-preferences-build}"
swift build --package-path "$project_dir/Packages/MorphKit" --scratch-path "$scratch_path"
product_dir="$(swift build --package-path "$project_dir/Packages/MorphKit" --scratch-path "$scratch_path" --show-bin-path)"
xcrun swiftc -parse-as-library \
  -I "$product_dir" -L "$product_dir" -lMorphServices -lMorphCore \
  "$project_dir/Morph/Design.swift" \
  "$project_dir/Morph/LanguageSettings.swift" \
  "$project_dir/Tests/DemoPreferencesTests.swift" \
  -o "$scratch_path/demo-preferences-tests"
"$scratch_path/demo-preferences-tests"
