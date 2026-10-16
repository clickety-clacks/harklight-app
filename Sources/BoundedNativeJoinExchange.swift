import Foundation
import Security

/// URLSession's data delegate preserves custom trust/identity challenges while
/// stopping an oversized response before it can accumulate in the app. The
/// lock also fences cancellation against callbacks and resumes a waiter once.
final class BoundedNativeJoinExchange: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let url: URL
    private let trust: EnrollmentTrustDelegate
    private let lock = NSLock()
    private let limit = 64 * 1024
    private var waiter: CheckedContinuation<NativeJoinResponse, Error>?
    private var task: URLSessionDataTask?
    private var response: HTTPURLResponse?
    private var body = Data()
    private var finished = false

    init(url: URL, rootDER: Data, identity: SecIdentity?) {
        self.url = url
        trust = EnrollmentTrustDelegate(host: url.host ?? "", rootDER: rootDER, identity: identity)
    }

    func run(session: URLSession, request: URLRequest) async throws -> NativeJoinResponse {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let next = session.dataTask(with: request)
                lock.lock()
                if finished {
                    lock.unlock()
                    next.cancel()
                    continuation.resume(throwing: CancellationError())
                    return
                }
                waiter = continuation
                task = next
                lock.unlock()
                next.resume()
            }
        } onCancel: {
            self.finish(.failure(CancellationError()))
        }
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        trust.urlSession(session, didReceive: challenge, completionHandler: completionHandler)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let response = response as? HTTPURLResponse, response.url == url,
              response.expectedContentLength <= Int64(limit) else {
            completionHandler(.cancel)
            finish(.failure(NativeJoinError.invalidResponse))
            return
        }
        lock.lock()
        let active = !finished
        if active { self.response = response }
        lock.unlock()
        completionHandler(active ? .allow : .cancel)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        guard data.count <= limit - body.count else {
            lock.unlock()
            finish(.failure(NativeJoinError.invalidResponse))
            return
        }
        body.append(data)
        lock.unlock()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { finish(.failure(error)); return }
        lock.lock()
        let value = response.map { NativeJoinResponse(statusCode: $0.statusCode, data: body) }
        lock.unlock()
        finish(value.map { .success($0) } ?? .failure(NativeJoinError.invalidResponse))
    }

    private func finish(_ result: Result<NativeJoinResponse, Error>) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        let waiting = waiter
        let active = task
        waiter = nil
        task = nil
        body.removeAll(keepingCapacity: false)
        lock.unlock()
        active?.cancel()
        waiting?.resume(with: result)
    }
}
