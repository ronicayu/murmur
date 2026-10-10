import Foundation

// MurmurEngine: the speech engine as a process of its own.
//
// usage: MurmurEngine <model directory>
//
// The app starts this process, sends it requests on standard input and reads
// replies from standard output (see EngineProtocol.swift). The model and the
// working memory of the runtime, 2 to 4 GB, live here, so the app gets them
// back from the system by ending this process.

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: MurmurEngine <model directory>\n".utf8))
    exit(64)
}

// The loop below notices that the app is gone only between requests, and a
// long file takes minutes. Do not decode for an app that no longer exists.
let parentWatch = DispatchSource.makeProcessSource(identifier: getppid(), eventMask: .exit, queue: .global())
parentWatch.setEventHandler { exit(0) }
parentWatch.resume()

let service = Qwen3TranscriptionService(
    modelDirectory: URL(fileURLWithPath: CommandLine.arguments[1]),
    // The app ends this process when it is idle; no second countdown here.
    idleUnloadSeconds: 24 * 60 * 60
)
let output = FileHandle.standardOutput
let server = EngineServer(service: service) { line in
    // Nothing else writes to standard output: the speech library logs to
    // standard error.
    try? output.write(contentsOf: line)
}

await server.run(lines: FileHandle.standardInput.bytes.lines)
