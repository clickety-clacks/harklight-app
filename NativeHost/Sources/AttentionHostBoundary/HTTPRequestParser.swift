import Foundation

public struct ParsedHTTPRequest: Sendable {
    public let head: HTTPRequestHead
    public let body: Data
}

/// Bounded single-request HTTP/1.1 framing. The foreground listener closes
/// each connection after one response, so pipelined or ambiguous framing is
/// rejected instead of assigning an account command to uncertain bytes.
public enum HTTPRequestParser {
    public static let maxHeaderBytes = 16_384
    public static let maxBodyBytes = 1_048_576

    public static func parse(_ raw: Data) throws -> ParsedHTTPRequest {
        let marker = Data("\r\n\r\n".utf8)
        guard let split = raw.range(of: marker), split.lowerBound <= maxHeaderBytes,
              let headText = String(data: raw[..<split.lowerBound], encoding: .utf8) else {
            throw HostBoundaryError.rejected
        }
        let lines = headText.components(separatedBy: "\r\n")
        guard let first = lines.first, !first.contains("\n"),
              !first.contains("\r"), lines.count >= 2 else { throw HostBoundaryError.rejected }
        let fields = first.split(separator: " ", omittingEmptySubsequences: false)
        guard fields.count == 3, fields[2] == "HTTP/1.1",
              fields[0] == "GET" || fields[0] == "POST",
              fields[1].hasPrefix("/"), !fields[1].contains("\n") else {
            throw HostBoundaryError.rejected
        }
        var headers: [String: [String]] = [:]
        for line in lines.dropFirst() {
            guard !line.isEmpty, !line.contains("\n"), !line.contains("\r"),
                  let colon = line.firstIndex(of: ":") else { throw HostBoundaryError.rejected }
            let name = String(line[..<colon])
            guard !name.isEmpty,
                  name.utf8.allSatisfy({ byte in
                      (byte >= 65 && byte <= 90) || (byte >= 97 && byte <= 122) ||
                      (byte >= 48 && byte <= 57) || byte == 45
                  }) else { throw HostBoundaryError.rejected }
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard !value.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else {
                throw HostBoundaryError.rejected
            }
            headers[name, default: []].append(value)
        }
        let head = HTTPRequestHead(method: String(fields[0]), path: String(fields[1]), headers: headers)
        guard head.soleHeader("Transfer-Encoding") == nil,
              !headers.keys.contains(where: { $0.caseInsensitiveCompare("Transfer-Encoding") == .orderedSame }) else {
            throw HostBoundaryError.rejected
        }
        let length: Int
        if head.method == "POST" {
            guard let encoded = head.soleHeader("Content-Length"),
                  !encoded.isEmpty, encoded.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }),
                  let parsed = Int(encoded), parsed <= maxBodyBytes else {
                throw HostBoundaryError.rejected
            }
            length = parsed
        } else {
            guard head.soleHeader("Content-Length") == nil else { throw HostBoundaryError.rejected }
            length = 0
        }
        let body = raw[split.upperBound...]
        guard body.count == length else { throw HostBoundaryError.rejected }
        return ParsedHTTPRequest(head: head, body: Data(body))
    }
}
