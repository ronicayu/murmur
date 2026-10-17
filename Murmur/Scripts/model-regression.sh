#!/bin/bash
# Runs the tests that need the real speech model, on a Mac without Xcode.
#
# `swift test` cannot build this package with only the Command Line Tools
# (the SwiftUI macros need Xcode), and CI has no model, so there the two
# transcription tests are skipped. This script compiles the speech service
# and its tests directly with swiftc, links the vendored speech library, and
# runs them against a model on this machine.
#
# usage: Scripts/model-regression.sh [model directory]
#   The model directory defaults to $MURMUR_MODEL_DIR, then to
#   ~/Library/Application Support/Murmur/Models-Qwen3ASR (where the app
#   downloads it).
set -euo pipefail

cd "$(dirname "$0")/.."
MODEL_DIR="${1:-${MURMUR_MODEL_DIR:-$HOME/Library/Application Support/Murmur/Models-Qwen3ASR}}"
if [ ! -f "$MODEL_DIR/decoder.int8.onnx" ]; then
    echo "No Qwen3-ASR model in: $MODEL_DIR" >&2
    echo "Download it in the app (Settings > Model), or pass its directory." >&2
    exit 2
fi

SHERPA=vendor/sherpa-onnx.xcframework/macos-arm64_x86_64
ORT_DIR="$PWD/.build/artifacts/onnxruntime-swift-package-manager/onnxruntime/onnxruntime.xcframework/macos-arm64_x86_64"
if [ ! -d "$ORT_DIR/onnxruntime.framework" ]; then
    swift package resolve
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# The tests as they are in the repository, with two changes: the import of
# XCTest gives way to the stand-in, and the model and fixture locations point
# at this machine. main.swift calls every test method in turn.
python3 - "$PWD" "$WORK" "$MODEL_DIR" <<'PY'
import re, sys
root, work, model = sys.argv[1:]
suites = []
for name, cls in [("Qwen3TranscriptionServiceTests", "Qwen3TranscriptionServiceTests"),
                  ("LongAudioSourceTests", "LongAudioSourceTests")]:
    text = open(f"{root}/Tests/{name}.swift").read()
    text = text.replace("import XCTest", "import Foundation").replace("@testable import Murmur\n", "")
    if name == "Qwen3TranscriptionServiceTests":
        start = text.index("    private var fixtureDir: URL {")
        end = text.index("    private func loadSamples")
        text = (text[:start]
                + f'    private var fixtureDir: URL {{ URL(fileURLWithPath: "{root}/test_fixtures") }}\n'
                + f'    private var modelDir: URL {{ URL(fileURLWithPath: "{model}") }}\n\n'
                + text[end:])
    open(f"{work}/{name}.swift", "w").write(text)
    suites.append((cls, re.findall(r"    func (test\w+)\(\)( async)?( throws)?", text)))

lines = ["import Foundation", "@main struct Runner { static func main() async {",
         "    var failed = 0, skipped = 0, total = 0"]
for cls, tests in suites:
    for test, is_async, throws in tests:
        call = ("try " if throws else "") + ("await " if is_async else "") + f"suite.{test}()"
        lines.append(f"""    do {{
        total += 1
        let suite = {cls}()
        var skip: String?
        do {{ try suite.setUpWithError(); {call}; try suite.tearDownWithError() }}
        catch let reason as XCTSkip {{ skip = reason.message }}
        catch is XCTUnwrapFailed {{}}
        catch {{ Failures.shared.add("threw \\(error)", #filePath, #line) }}
        let failures = Failures.shared.take()
        if !failures.isEmpty {{ failed += 1; print("FAIL  {cls}.{test}"); failures.forEach {{ print("        \\($0)") }} }}
        else if let skip {{ skipped += 1; print("SKIP  {cls}.{test}  \\(skip)") }}
        else {{ print("pass  {cls}.{test}") }}
    }}""")
lines += ['    print("\\(total) tests, \\(failed) failed, \\(skipped) skipped")',
          "    exit(failed == 0 ? 0 : 1)", "} }"]
open(f"{work}/main.swift", "w").write("\n".join(lines) + "\n")
PY

echo "Building…"
swiftc -O -parse-as-library -module-name Murmur -o "$WORK/run" \
    -I "$SHERPA/Headers" -L "$SHERPA" -lsherpa-onnx -lc++ \
    -F "$ORT_DIR" -framework onnxruntime -Xlinker -rpath -Xlinker "$ORT_DIR" \
    Services/Vendor/SherpaOnnx.swift Services/Qwen3TranscriptionService.swift \
    Services/LongAudioSource.swift Services/IdleTrigger.swift Services/SpokenLanguages.swift \
    Services/TranscriptionTypes.swift MurmurError.swift Services/ModelManager.swift Services/HFDownload.swift \
    Services/LongTranscription.swift Services/TemporaryAudio.swift \
    Scripts/model-regression/XCTestStandIn.swift "$WORK"/*.swift 2> "$WORK/build.log" \
    || { grep -E "error" "$WORK/build.log" | head -20 >&2; exit 1; }

# The speech library logs its configuration to stderr; keep our lines only.
"$WORK/run" 2> "$WORK/run.log" || { status=$?; grep -vE "^\[|^$" "$WORK/run.log" | tail -5 >&2; exit $status; }
