/// Local failure before an authenticated client API request can be made.
public enum ClientConnectionError: Error, Sendable {
    case invalidEndpoint
    case invalidTrustAnchor
    case inactive
}
