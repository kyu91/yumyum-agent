import Darwin
import Foundation

public enum ProcessOutputStream: String, Equatable, Sendable {
    case standardOutput
    case standardError
}

public enum ProcessRunnerError: Error, Equatable, Sendable {
    case launchFailed(executablePath: String, reason: String)
    case outputReadFailed(stream: ProcessOutputStream, reason: String)
}

public struct ProcessRunner: ProcessRunning, Sendable {
    private let terminationGracePeriod: Duration
    private let outputDrainGracePeriod: Duration = .milliseconds(100)

    public init(terminationGracePeriod: Duration = .milliseconds(250)) {
        self.terminationGracePeriod = terminationGracePeriod
    }

    public func run(
        _ command: ProcessCommand,
        timeout: Duration? = nil
    ) async throws -> ProcessRunResult {
        let process = Process()
        process.executableURL = command.executableURL
        process.arguments = command.arguments
        if let environment = command.environment {
            process.environment = environment
        }
        process.currentDirectoryURL = command.currentDirectoryURL

        let standardOutputPipe = Pipe()
        let standardErrorPipe = Pipe()
        process.standardOutput = standardOutputPipe
        process.standardError = standardErrorPipe

        let controller = ChildProcessController(
            process: process,
            terminationGracePeriod: terminationGracePeriod
        )
        let observedTermination = AsyncLatch<ProcessTermination>()
        let completion = AsyncLatch<Completion>()

        process.terminationHandler = { terminatedProcess in
            let termination: ProcessTermination
            switch terminatedProcess.terminationReason {
            case .exit:
                termination = .exited(status: terminatedProcess.terminationStatus)
            case .uncaughtSignal:
                termination = .uncaughtSignal(signal: terminatedProcess.terminationStatus)
            @unknown default:
                termination = .uncaughtSignal(signal: terminatedProcess.terminationStatus)
            }

            controller.markFinished()
            observedTermination.resolve(termination)
            completion.resolve(.terminated)
        }

        return try await withTaskCancellationHandler {
            try Task.checkCancellation()

            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                closeAllHandles(standardOutputPipe)
                closeAllHandles(standardErrorPipe)
                throw ProcessRunnerError.launchFailed(
                    executablePath: command.executableURL.path,
                    reason: String(describing: error)
                )
            }

            controller.markLaunched()
            try? standardOutputPipe.fileHandleForWriting.close()
            try? standardErrorPipe.fileHandleForWriting.close()

            let outputBudget = ProcessOutputBudget(limit: command.outputByteLimit)
            let standardOutputReader = PipeReader(
                fileHandle: standardOutputPipe.fileHandleForReading,
                outputBudget: outputBudget
            )
            let standardErrorReader = PipeReader(
                fileHandle: standardErrorPipe.fileHandleForReading,
                outputBudget: outputBudget
            )
            let standardOutputTask = Task.detached {
                try standardOutputReader.readToEnd()
            }
            let standardErrorTask = Task.detached {
                try standardErrorReader.readToEnd()
            }

            let timeoutTask = timeout.map { timeout in
                Task.detached {
                    do {
                        try await ContinuousClock().sleep(for: timeout)
                    } catch {
                        return
                    }

                    if completion.resolve(.timedOut) {
                        controller.requestStop()
                    }
                }
            }

            let completedBy = await completion.wait()
            timeoutTask?.cancel()
            if let timeoutTask {
                await timeoutTask.value
            }

            if completedBy == .timedOut {
                controller.requestStop()
            }
            let termination = await observedTermination.wait()

            let outputDrainTask = Task.detached {
                do {
                    try await ContinuousClock().sleep(for: outputDrainGracePeriod)
                } catch {
                    return
                }
                standardOutputReader.requestStop()
                standardErrorReader.requestStop()
            }

            let standardOutput = await read(
                standardOutputTask,
                stream: .standardOutput
            )
            let standardError = await read(
                standardErrorTask,
                stream: .standardError
            )
            outputDrainTask.cancel()
            await outputDrainTask.value
            process.terminationHandler = nil

            if Task.isCancelled {
                throw CancellationError()
            }
            if case let .failure(error) = standardOutput {
                throw error
            }
            if case let .failure(error) = standardError {
                throw error
            }

            return ProcessRunResult(
                standardOutput: try standardOutput.get(),
                standardError: try standardError.get(),
                termination: completedBy == .timedOut ? .timedOut : termination
            )
        } onCancel: {
            controller.requestStop()
        }
    }

    private func read(
        _ task: Task<Data, any Error>,
        stream: ProcessOutputStream
    ) async -> Result<Data, ProcessRunnerError> {
        do {
            return .success(try await task.value)
        } catch {
            return .failure(
                .outputReadFailed(stream: stream, reason: String(describing: error))
            )
        }
    }

    private func closeAllHandles(_ pipe: Pipe) {
        try? pipe.fileHandleForReading.close()
        try? pipe.fileHandleForWriting.close()
    }
}

private enum Completion: Sendable {
    case terminated
    case timedOut
}

private final class PipeReader: @unchecked Sendable {
    private let lock = NSLock()
    private let fileHandle: FileHandle
    private let outputBudget: ProcessOutputBudget
    private var stopRequested = false

    init(fileHandle: FileHandle, outputBudget: ProcessOutputBudget) {
        self.fileHandle = fileHandle
        self.outputBudget = outputBudget
    }

    func requestStop() {
        lock.lock()
        stopRequested = true
        lock.unlock()
    }

    func readToEnd() throws -> Data {
        defer { try? fileHandle.close() }
        let fileDescriptor = fileHandle.fileDescriptor
        let flags = fcntl(fileDescriptor, F_GETFL)
        guard flags != -1, fcntl(fileDescriptor, F_SETFL, flags | O_NONBLOCK) != -1 else {
            throw currentPOSIXError()
        }

        var output = Data()
        var buffer = [UInt8](repeating: 0, count: 16_384)

        while true {
            let byteCount = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(fileDescriptor, bytes.baseAddress, bytes.count)
            }

            if byteCount > 0 {
                let bytesRead = Int(byteCount)
                let bytesToKeep = outputBudget.reserve(upTo: bytesRead)
                output.append(contentsOf: buffer.prefix(bytesToKeep))
                if shouldStop {
                    return output
                }
                continue
            }
            if byteCount == 0 {
                return output
            }

            let readError = errno
            if readError == EINTR {
                continue
            }
            guard readError == EAGAIN || readError == EWOULDBLOCK else {
                throw posixError(readError)
            }
            if shouldStop {
                return output
            }

            var descriptor = pollfd(
                fd: fileDescriptor,
                events: Int16(POLLIN | POLLHUP | POLLERR),
                revents: 0
            )
            let pollResult = Darwin.poll(&descriptor, 1, 20)
            if pollResult == -1, errno != EINTR {
                throw currentPOSIXError()
            }
        }
    }

    private var shouldStop: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopRequested
    }

    private func currentPOSIXError() -> NSError {
        posixError(errno)
    }

    private func posixError(_ code: Int32) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(code))
    }
}

private final class ProcessOutputBudget: @unchecked Sendable {
    private let lock = NSLock()
    private var remaining: Int?

    init(limit: Int?) {
        remaining = limit.map { max(0, $0) }
    }

    func reserve(upTo requested: Int) -> Int {
        lock.lock()
        defer { lock.unlock() }
        guard let remaining else {
            return requested
        }
        let granted = min(requested, remaining)
        self.remaining = remaining - granted
        return granted
    }
}

private final class AsyncLatch<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value?
    private var continuation: CheckedContinuation<Value, Never>?

    @discardableResult
    func resolve(_ value: Value) -> Bool {
        let continuation: CheckedContinuation<Value, Never>?

        lock.lock()
        guard self.value == nil else {
            lock.unlock()
            return false
        }
        self.value = value
        continuation = self.continuation
        self.continuation = nil
        lock.unlock()

        continuation?.resume(returning: value)
        return true
    }

    func wait() async -> Value {
        await withCheckedContinuation { continuation in
            lock.lock()
            if let value {
                lock.unlock()
                continuation.resume(returning: value)
            } else {
                self.continuation = continuation
                lock.unlock()
            }
        }
    }
}

private final class ChildProcessController: @unchecked Sendable {
    private let lock = NSLock()
    private let process: Process
    private let terminationGracePeriod: Duration
    private var launched = false
    private var finished = false
    private var stopRequested = false
    private var stopSequenceStarted = false

    init(process: Process, terminationGracePeriod: Duration) {
        self.process = process
        self.terminationGracePeriod = terminationGracePeriod
    }

    func markLaunched() {
        lock.lock()
        launched = true
        let shouldStop = stopRequested
        lock.unlock()

        if shouldStop {
            requestStop()
        }
    }

    func markFinished() {
        lock.lock()
        finished = true
        lock.unlock()
    }

    func requestStop() {
        lock.lock()
        stopRequested = true
        guard launched, !finished, !stopSequenceStarted else {
            lock.unlock()
            return
        }
        stopSequenceStarted = true
        lock.unlock()

        if process.isRunning {
            process.terminate()
        }

        Task.detached { [self] in
            try? await ContinuousClock().sleep(for: terminationGracePeriod)
            forceKillIfRunning()
        }
    }

    private func forceKillIfRunning() {
        lock.lock()
        defer { lock.unlock() }
        guard launched, !finished, process.isRunning else {
            return
        }
        Darwin.kill(process.processIdentifier, SIGKILL)
    }
}
