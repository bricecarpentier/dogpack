import Foundation
import Testing

private let productDir = {
    let dir = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent(".build/debug")
    return dir.path
}()

@Test
func `dogpack exits non-zero with usage when args are missing`() throws {
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "\(productDir)/dogpack")
    let pipe = Pipe()
    proc.standardOutput = pipe
    proc.standardError = pipe

    try proc.run()
    proc.waitUntilExit()

    #expect(proc.terminationStatus != 0)

    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    let output = String(data: data, encoding: .utf8) ?? ""
    #expect(output.contains("Usage:"))
    #expect(output.contains("--url"))
    #expect(output.contains("--api-key"))
    #expect(output.contains("--model"))
}
