import Foundation

/// A request that carries an API key goes to the service's own host and nowhere else. If the
/// service answers with a redirect to another host, it is not followed: the redirect itself
/// becomes the answer ("<Service> answered HTTP 302"), and the key never leaves for an
/// address that came in a response. Used by every call that sends a key.
public final class KeyStaysHome: NSObject, URLSessionTaskDelegate, Sendable {
    public static let shared = KeyStaysHome()

    /// Whether a redirect from `original` to `next` stays on the same host over https (or stays on this Mac).
    public static func mayFollow(from original: URL?, to next: URL?) -> Bool {
        guard let from = original?.host()?.lowercased(), let to = next?.host()?.lowercased(), from == to else { return false }
        return next?.scheme?.lowercased() == original?.scheme?.lowercased()
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                           newRequest request: URLRequest) async -> URLRequest? {
        Self.mayFollow(from: task.originalRequest?.url, to: request.url) ? request : nil
    }

    /// A link that came in a service's answer and is fetched without the key (a signed
    /// download): https with a host, nothing else. Never a file, never plain http.
    public static func fetchable(_ text: String?) -> URL? {
        guard let text, let url = URL(string: text), url.scheme?.lowercased() == "https", let host = url.host(), !host.isEmpty else { return nil }
        return url
    }

    /// An identifier from a service's answer that goes into a path of a request with the key:
    /// letters, digits, "-" and "_" only, so it can't change where the request goes.
    public static func pathSafe(_ id: String?) -> String? {
        guard let id, !id.isEmpty, id.count <= 200,
              id.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) && $0.isASCII || $0 == "-" || $0 == "_" }) else { return nil }
        return id
    }
}
