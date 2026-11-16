import Foundation
import NetworkGuardLoader
import ObjectiveC

/// No test reaches anything but this Mac unless it has replaced the transport itself.
///
/// Loaded into every test process before any test runs (a constructor in NetworkGuardLoader).
/// It is first in line for `URLSession.shared` and for every session made from the default or
/// ephemeral configuration, refuses any request whose host is not this Mac before a name is
/// looked up or a connection opened, and makes the whole run fail when that happened. A test
/// that sets its own `protocolClasses` (the fakes) replaces it for that session, which is the
/// point: that test answers everything itself. `AppSourceRuleTests` checks that the fakes are
/// the only sessions tests build.
///
/// Tests that need a public host on purpose are network tests: run them separately with
/// GLIMMER_NETWORK_TESTS=1 (or the live suites' GLIMMER_LIVE_AI=1), and the run says so.
public final class NetworkGuard: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var refused: [String] = []
    public static var violations: [String] { lock.withLock { refused } }

    public static let allowsPublicHosts: Bool = {
        let env = ProcessInfo.processInfo.environment
        return env["GLIMMER_NETWORK_TESTS"] == "1" || env["GLIMMER_LIVE_AI"] == "1"
    }()

    static func isThisMac(_ host: String?) -> Bool {
        guard let host = host?.lowercased() else { return true }   // file:, data: and the like
        return ["127.0.0.1", "localhost", "::1", "[::1]"].contains(host) || host.hasSuffix(".localhost")
    }

    public override class func canInit(with request: URLRequest) -> Bool {
        guard !allowsPublicHosts, let url = request.url, let scheme = url.scheme?.lowercased(),
              ["http", "https", "ws", "wss"].contains(scheme) else { return false }
        return !isThisMac(url.host)
    }

    public override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    public override func startLoading() {
        let host = request.url?.host ?? "?"
        let line = "\(request.httpMethod ?? "GET") \(host)\(request.url?.path ?? "")"
        Self.lock.withLock { Self.refused.append(line) }
        FileHandle.standardError.write(Data("✘ NetworkGuard: a test tried to reach \(line). Nothing was sent. Replace the transport in the test, or mark it a network test.\n".utf8))
        client?.urlProtocol(self, didFailWithError: NSError(domain: "NetworkGuard", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "A test tried to reach \(host), which is not this Mac. Nothing was sent."]))
    }

    public override func stopLoading() {}

    static func install() {
        URLProtocol.registerClass(NetworkGuard.self)
        // Sessions made from the default or ephemeral configuration get the guard first in line too.
        for name in ["defaultSessionConfiguration", "ephemeralSessionConfiguration"] {
            let selector = NSSelectorFromString(name)
            guard let method = class_getClassMethod(URLSessionConfiguration.self, selector) else { continue }
            typealias Getter = @convention(c) (AnyClass, Selector) -> URLSessionConfiguration
            let original = unsafeBitCast(method_getImplementation(method), to: Getter.self)
            let replacement: @convention(block) (AnyClass) -> URLSessionConfiguration = { cls in
                let configuration = original(cls, selector)
                configuration.protocolClasses = [NetworkGuard.self] + (configuration.protocolClasses ?? []).filter { $0 != NetworkGuard.self }
                return configuration
            }
            method_setImplementation(method, imp_implementationWithBlock(replacement))
        }
        if allowsPublicHosts {
            FileHandle.standardError.write(Data("▸ NetworkGuard: NETWORK TESTS, public hosts are allowed in this run.\n".utf8))
        }
        atexit {
            let refused = NetworkGuard.violations
            guard !refused.isEmpty else { return }
            FileHandle.standardError.write(Data("✘ NetworkGuard: \(refused.count) request(s) to hosts other than this Mac were refused: \(Set(refused).sorted().joined(separator: "; ")). The run fails.\n".utf8))
            _exit(1)
        }
    }
}

@_cdecl("glimmer_install_network_guard")
public func glimmerInstallNetworkGuard() { NetworkGuard.install() }
