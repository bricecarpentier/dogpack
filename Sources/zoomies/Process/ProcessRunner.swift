import Foundation

private let WIFEXITED: @Sendable (Int32) -> Bool = { status in (status & 0o177) == 0 }
private let WEXITSTATUS: @Sendable (Int32) -> Int32 = { status in (status >> 8) & 0xFF }

/// Result of a subprocess execution.
public struct ProcessResult: Sendable {
    public let output: String
    public let exitCode: Int32
    public let timedOut: Bool
}

/// Spawns subprocesses via `posix_spawn` with process-group isolation.
/// Each child runs in its own process group so `kill(-pid, SIGKILL)` takes
/// down the entire tree on timeout — no orphaned children.
public enum ProcessRunner {
    /// Execute a bash command with an optional working directory and timeout.
    public static func run(
        _ command: String,
        workingDirectory: String? = nil,
        timeout: TimeInterval = 30,
    ) async -> ProcessResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                let result = spawn(
                    command: command,
                    workingDirectory: workingDirectory,
                    timeout: timeout,
                )
                continuation.resume(returning: result)
            }
        }
    }

    // MARK: - Private

    private static func spawn(
        command: String,
        workingDirectory: String?,
        timeout: TimeInterval,
    ) -> ProcessResult {
        var stdoutPipe = [CInt](repeating: -1, count: 2)
        var stderrPipe = [CInt](repeating: -1, count: 2)
        guard pipe(&stdoutPipe) == 0, pipe(&stderrPipe) == 0 else {
            return ProcessResult(
                output: "Error: failed to create pipes: \(String(cString: strerror(errno)))",
                exitCode: 1,
                timedOut: false,
            )
        }

        guard let spawnContext = prepareSpawnContext(
            command: command,
            workingDirectory: workingDirectory,
            stdoutPipe: stdoutPipe,
            stderrPipe: stderrPipe,
        ) else {
            close(stdoutPipe[0]); close(stdoutPipe[1])
            close(stderrPipe[0]); close(stderrPipe[1])
            return ProcessResult(
                output: "Error: failed to prepare spawn context",
                exitCode: 1,
                timedOut: false,
            )
        }

        var pid: pid_t = 0
        let spawnResult = posix_spawn(
            &pid,
            "/bin/bash",
            &spawnContext.fileActions,
            &spawnContext.attr,
            &spawnContext.argv,
            &spawnContext.envp,
        )

        guard spawnResult == 0 else {
            close(stdoutPipe[0]); close(stdoutPipe[1])
            close(stderrPipe[0]); close(stderrPipe[1])
            return ProcessResult(
                output: "Error: posix_spawn failed: \(String(cString: strerror(spawnResult)))",
                exitCode: 1,
                timedOut: false,
            )
        }

        return waitForCompletionAndCollect(
            pid: pid,
            stdoutPipe: stdoutPipe,
            stderrPipe: stderrPipe,
            timeout: timeout,
        )
    }

    private static func waitForCompletionAndCollect(
        pid: pid_t,
        stdoutPipe: [CInt],
        stderrPipe: [CInt],
        timeout: TimeInterval,
    ) -> ProcessResult {
        // Parent: close write ends
        close(stdoutPipe[1])
        close(stderrPipe[1])

        let waitResult = waitForProcess(pid: pid, timeout: timeout)
        let timedOut = waitResult == nil

        if timedOut {
            kill(-pid, SIGKILL)
            // Collect zombie after kill
            var status: Int32 = 0
            waitpid(pid, &status, 0)
        }

        let stdoutData = readFileDescriptor(stdoutPipe[0])
        let stderrData = readFileDescriptor(stderrPipe[0])
        close(stdoutPipe[0])
        close(stderrPipe[0])

        let status = waitResult ?? 0
        return buildResult(
            stdoutData: stdoutData,
            stderrData: stderrData,
            status: status,
            timedOut: timedOut,
            timeout: timeout,
        )
    }

    private final class SpawnContext {
        var attr: posix_spawnattr_t?
        var fileActions: posix_spawn_file_actions_t?
        var argv: [UnsafeMutablePointer<CChar>?]
        var envp: [UnsafeMutablePointer<CChar>?]

        init(
            attr: posix_spawnattr_t?,
            fileActions: posix_spawn_file_actions_t?,
            argv: [UnsafeMutablePointer<CChar>?],
            envp: [UnsafeMutablePointer<CChar>?],
        ) {
            self.attr = attr
            self.fileActions = fileActions
            self.argv = argv
            self.envp = envp
        }

        deinit {
            posix_spawnattr_destroy(&attr)
            posix_spawn_file_actions_destroy(&fileActions)
            for ptr in argv {
                free(ptr)
            }
            for ptr in envp {
                free(ptr)
            }
        }
    }

    private static func prepareSpawnContext(
        command: String,
        workingDirectory: String?,
        stdoutPipe: [CInt],
        stderrPipe: [CInt],
    ) -> SpawnContext? {
        // Build argv
        let bash = "/bin/bash"
        let dashC = "-c"
        var argv: [UnsafeMutablePointer<CChar>?] = [
            strdup(bash), strdup(dashC), strdup(command), nil,
        ]

        // Build envp (inherit current environment)
        var envp: [UnsafeMutablePointer<CChar>?] = []
        let env = environ
        var envIndex = 0
        while env[envIndex] != nil {
            guard let entry = env[envIndex] else { break }
            envp.append(strdup(entry))
            envIndex += 1
        }
        envp.append(nil)

        // Spawn attributes: new process group
        var attr: posix_spawnattr_t?
        guard posix_spawnattr_init(&attr) == 0 else { return nil }
        var flags = Int16(POSIX_SPAWN_SETPGROUP)
        posix_spawnattr_setflags(&attr, flags)
        posix_spawnattr_setpgroup(&attr, 0)

        // File actions: pipe redirection
        var fileActions: posix_spawn_file_actions_t?
        guard posix_spawn_file_actions_init(&fileActions) == 0 else { return nil }

        posix_spawn_file_actions_addclose(&fileActions, stdoutPipe[0])
        posix_spawn_file_actions_addclose(&fileActions, stderrPipe[0])
        posix_spawn_file_actions_adddup2(&fileActions, stdoutPipe[1], STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&fileActions, stderrPipe[1], STDERR_FILENO)
        posix_spawn_file_actions_addclose(&fileActions, stdoutPipe[1])
        posix_spawn_file_actions_addclose(&fileActions, stderrPipe[1])

        if let workingDirectory {
            posix_spawn_file_actions_addchdir_np(&fileActions, workingDirectory)
        }

        return SpawnContext(attr: attr, fileActions: fileActions, argv: argv, envp: envp)
    }

    private static func buildResult(
        stdoutData: Data,
        stderrData: Data,
        status: Int32,
        timedOut: Bool,
        timeout: TimeInterval,
    ) -> ProcessResult {
        let stdoutStr = String(data: stdoutData, encoding: .utf8) ?? ""
        let stderrStr = String(data: stderrData, encoding: .utf8) ?? ""

        if timedOut {
            return ProcessResult(
                output: "Command timed out after \(Int(timeout))s\n\(stderrStr)",
                exitCode: -1,
                timedOut: true,
            )
        }

        let exitCode = WIFEXITED(status) ? WEXITSTATUS(status) : -1
        var output = ""
        if exitCode == 0 {
            output = stdoutStr
        } else {
            if !stdoutStr.isEmpty { output += stdoutStr + "\n" }
            if !stderrStr.isEmpty { output += "stderr: " + stderrStr }
            output += "exit code: \(exitCode)"
        }
        return ProcessResult(output: output, exitCode: exitCode, timedOut: false)
    }

    /// Poll for process completion with a timeout.
    /// Returns the wait status if the process exited, or nil on timeout.
    private static func waitForProcess(pid: pid_t, timeout: TimeInterval) -> Int32? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            var status: Int32 = 0
            let result = waitpid(pid, &status, WNOHANG)
            if result > 0 { return status }
            usleep(50000) // 50ms poll interval
        }
        return nil
    }

    /// Read all available data from a file descriptor.
    private static func readFileDescriptor(_ fileDescriptor: CInt) -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let bytesRead = read(fileDescriptor, &buffer, buffer.count)
            if bytesRead <= 0 { break }
            data.append(buffer, count: bytesRead)
        }
        return data
    }
}
