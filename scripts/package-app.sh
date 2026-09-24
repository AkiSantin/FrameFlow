#!/bin/bash
set -euo pipefail
if [[ $# -ne 2 ]]; then
  echo "usage: bash scripts/package-app.sh OUTPUT_PARENT SCRATCH_PATH" >&2
  exit 2
fi
script_dir="$(cd "$(dirname "$0")" && pwd)"
project_dir="$(cd "$script_dir/.." && pwd)"
output_parent="$1"
scratch_path="$2"
if [[ -e "$output_parent" || -e "$scratch_path" ]]; then
  echo "output and scratch paths must not already exist" >&2
  exit 3
fi
mkdir -p "$output_parent" "$scratch_path"
output_parent="$(cd "$output_parent" && pwd)"
scratch_path="$(cd "$scratch_path" && pwd)"
staging_app="$output_parent/.FrameFlow.staging.app"
final_app="$output_parent/FrameFlow.app"
CLANG_MODULE_CACHE_PATH="$scratch_path/clang-cache" SWIFTPM_MODULECACHE_OVERRIDE="$scratch_path/module-cache" \
/usr/bin/swift build --cache-path "$scratch_path/spm-cache" --config-path "$scratch_path/spm-config" --security-path "$scratch_path/spm-security" --package-path "$project_dir" --configuration release --product FrameFlowApp --scratch-path "$scratch_path" \
  -Xswiftc -debug-prefix-map -Xswiftc "$project_dir=/FrameFlow" \
  -Xswiftc -file-prefix-map -Xswiftc "$project_dir=/FrameFlow" \
  -Xswiftc -debug-prefix-map -Xswiftc "$scratch_path=/Build" \
  -Xswiftc -file-prefix-map -Xswiftc "$scratch_path=/Build" \
  -Xlinker -no_adhoc_codesign
mkdir -p "$staging_app/Contents/MacOS" "$staging_app/Contents/Resources"
# strip writes a new output, leaving the compiler output untouched.
/usr/bin/strip -S -x -o "$staging_app/Contents/MacOS/FrameFlow" "$scratch_path/release/FrameFlowApp"
cp "$project_dir/Info.plist" "$staging_app/Contents/Info.plist"
cp -R "$project_dir/Sources/FrameFlowUI/Resources" "$staging_app/Contents/Resources/FrameFlowResources"
cp "$project_dir/Assets/AppIcon.icns" "$staging_app/Contents/Resources/AppIcon.icns"
/usr/bin/codesign --sign - "$staging_app"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$staging_app"
mv -n "$staging_app" "$final_app"
echo "$final_app"

