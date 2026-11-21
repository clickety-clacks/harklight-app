#!/usr/bin/env python3
"""Build overlay for the private synthetic fixture only. Never commit it to the app."""
from pathlib import Path
from shutil import copyfile
import sys

source = Path(sys.argv[1])
test = Path(sys.argv[2])


def edit(relative_path, anchor, replacement):
    file = source / relative_path
    text = file.read_text()
    if text.count(anchor) != 1:
        raise SystemExit(f"Unexpected source anchor in {relative_path}")
    file.write_text(text.replace(anchor, replacement))


edit(
    "Sources/NativeRelayLifecycle.swift",
    "    static let shared = NativeRelayLifecycle()",
    "    static let shared = NativeRelayLifecycle(clientAPIV2Enabled: true)",
)
edit(
    "Sources/NativeGuidedJoin.swift",
    '        try await send(url, method: "POST", body: body, rootDER: rootDER, identity: identity)\n    }\n\n    private func send(',
    """        if url.host == "localhost", url.port == 18444, url.path == "/device/remove",
           ProcessInfo.processInfo.environment["HARKLIGHT_B3_OFFLINE_REMOVAL"] == "1" {
            throw URLError(.notConnectedToInternet)
        }
        return try await send(url, method: "POST", body: body, rootDER: rootDER, identity: identity)
    }

    private func send(""",
)
edit(
    "NativeRelay/Sources/HarklightNativeRelay/ClientAPIv2/HTTPSClientAPITransport.swift",
    "    public func send(_ request: APIRequest) async throws -> APIResponse {\n",
    """    public func send(_ request: APIRequest) async throws -> APIResponse {
        if baseURL.host == "localhost", baseURL.port == 18443,
           request.method == .post, request.path.hasSuffix("/replies"),
           ProcessInfo.processInfo.environment["HARKLIGHT_B3_OFFLINE_REPLY"] == "1" {
            throw URLError(.notConnectedToInternet)
        }
""",
)
copyfile(test, source / "UITests/B3EnrollmentProof.swift")
