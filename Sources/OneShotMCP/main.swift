import Darwin
import Foundation
import OneShotCore

@main
enum OneShotMCP {
    static func main() {
        signal(SIGPIPE, SIG_IGN)
        let arguments = Array(CommandLine.arguments.dropFirst())
        do {
            let server: OneShotMCPServer
            if arguments == ["--library"] || arguments.isEmpty {
                server = OneShotMCPServer(library: HandoffLibrary())
            } else if arguments.count == 2, arguments[0] == "--library", arguments[1].hasPrefix("/") {
                server = OneShotMCPServer(library: HandoffLibrary(directory: URL(fileURLWithPath: arguments[1], isDirectory: true)))
            } else if arguments.count == 2, arguments[0] == "--handoff", arguments[1].hasPrefix("/") {
                server = OneShotMCPServer(reader: try ReadonlyHandoffReader(directory: URL(fileURLWithPath: arguments[1], isDirectory: true)))
            } else {
                fail("Usage: oneshot-mcp --library [absolute-library-path] | --handoff /absolute/path/to/one-export")
            }
            var buffer = Data()
            var input = [UInt8](repeating: 0, count: 65_536)
            while true {
                // Foundation's read(upToCount:) can wait to fill the requested size
                // on a pipe. MCP clients keep stdin open between small requests, so
                // use one POSIX read and process the currently available bytes.
                let count = input.withUnsafeMutableBytes { Darwin.read(STDIN_FILENO, $0.baseAddress!, $0.count) }
                if count < 0, errno == EINTR { continue }
                guard count >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
                if count == 0 { break }
                buffer.append(contentsOf: input.prefix(count))
                while let newline = buffer.firstIndex(of: 10) {
                    let line = Data(buffer[..<newline])
                    buffer.removeSubrange(...newline)
                    if let response = server.handle(line) {
                        try FileHandle.standardOutput.write(contentsOf: response + Data([10]))
                    }
                }
                guard buffer.count <= OneShotMCPServer.maximumRequestBytes else {
                    fail("MCP request exceeds 1 MiB; stopping this stdio session.")
                }
            }
            if !buffer.isEmpty, let response = server.handle(buffer) {
                try FileHandle.standardOutput.write(contentsOf: response + Data([10]))
            }
        } catch { fail(error.localizedDescription) }
    }

    private static func fail(_ message: String) -> Never {
        try? FileHandle.standardError.write(contentsOf: Data((message + "\n").utf8))
        exit(1)
    }
}
