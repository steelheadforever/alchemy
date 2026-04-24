import Foundation

public protocol GatewayTransporting: Sendable {
    func connect(to url: URL) async throws
    func send(text: String) async throws
    func receiveText() async throws -> String
    func disconnect() async
}

public actor URLSessionGatewayTransport: GatewayTransporting {
    private let session: URLSession
    private let delegate: WebSocketDiagnosticsDelegate?
    private var task: URLSessionWebSocketTask?

    public init(session: URLSession? = nil) {
        let delegate = WebSocketDiagnosticsDelegate()
        self.delegate = delegate
        self.session = session
            ?? URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
    }

    public init(session: URLSession) {
        self.delegate = nil
        self.session = session
    }

    public func connect(to url: URL) async throws {
        let task = session.webSocketTask(with: url)
        self.task = task
        task.resume()
    }

    public func send(text: String) async throws {
        guard let task else {
            throw GatewayClientError.notConnected
        }

        try await task.send(.string(text))
    }

    public func receiveText() async throws -> String {
        guard let task else {
            throw GatewayClientError.notConnected
        }

        let message: URLSessionWebSocketTask.Message
        do {
            message = try await task.receive()
        } catch {
            if task.closeCode != .invalid {
                let reason = task.closeReason.flatMap { String(data: $0, encoding: .utf8) } ?? "<none>"
                throw GatewayClientError.disconnected(
                    "WebSocket closed before a gateway response was received (code \(task.closeCode.rawValue), reason: \(reason))"
                )
            }
            throw error
        }

        switch message {
        case .string(let text):
            return text
        case .data(let data):
            guard let text = String(data: data, encoding: .utf8) else {
                throw GatewayClientError.invalidMessage
            }
            return text
        @unknown default:
            throw GatewayClientError.unsupportedFrame
        }
    }

    public func disconnect() async {
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
    }
}

private final class WebSocketDiagnosticsDelegate: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: (any Error)?
    ) {
        guard let error else {
            return
        }

        let nsError = error as NSError
        print(
            """
            Alchemy Gateway WebSocket failed: \(String(reflecting: error)) \
            domain=\(nsError.domain) code=\(nsError.code) \
            failingURL=\(nsError.userInfo[NSURLErrorFailingURLStringErrorKey] ?? "<none>")
            """
        )
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocol: String?
    ) {
        print("Alchemy Gateway WebSocket opened.")
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        let reasonText = reason.flatMap { String(data: $0, encoding: .utf8) } ?? "<none>"
        print("Alchemy Gateway WebSocket closed: code=\(closeCode.rawValue) reason=\(reasonText)")
    }
}
