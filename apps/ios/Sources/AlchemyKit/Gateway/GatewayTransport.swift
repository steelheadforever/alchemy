import Foundation

public protocol GatewayTransporting: Sendable {
    func connect(to url: URL) async throws
    func send(text: String) async throws
    func receiveText() async throws -> String
    func disconnect() async
}

public actor URLSessionGatewayTransport: GatewayTransporting {
    private let session: URLSession
    private var task: URLSessionWebSocketTask?

    public init(session: URLSession = .shared) {
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

        let message = try await task.receive()

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

