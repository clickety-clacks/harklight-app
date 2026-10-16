import Foundation

public struct BundledHostPage: Sendable {
    public init() {}

    /// Static assets contain no account data. Until the C native port adapter
    /// is installed, every API request fails closed with no semantic effect.
    public func reply(_ request: ParsedHTTPRequest, boundary: HostHTTPBoundary) -> HTTPReply {
        if request.head.path.hasPrefix("/api/") {
            guard (try? boundary.validateAPI(request.head)) != nil else {
                return json(403, "boundary_rejected")
            }
            return json(503, "native_port_unavailable")
        }
        guard (try? boundary.validateStatic(request.head)) != nil else {
            return json(404, "not_found")
        }
        let filename = request.head.path == "/" ? "index.html" :
            String(request.head.path.dropFirst())
        let parts = filename.split(separator: ".")
        guard parts.count == 2,
              let url = Bundle.module.url(forResource: String(parts[0]), withExtension: String(parts[1])),
              let body = try? Data(contentsOf: url) else {
            return json(404, "not_found")
        }
        let type: String
        switch filename {
        case "index.html": type = "text/html; charset=utf-8"
        case "app.js", "sender.js": type = "text/javascript; charset=utf-8"
        case "app.css": type = "text/css; charset=utf-8"
        default: return json(404, "not_found")
        }
        return HTTPReply(status: 200, contentType: type, body: body, staticAsset: true)
    }

    private func json(_ status: Int, _ error: String) -> HTTPReply {
        HTTPReply(status: status, body: Data("{\"error\":\"\(error)\"}".utf8))
    }
}
