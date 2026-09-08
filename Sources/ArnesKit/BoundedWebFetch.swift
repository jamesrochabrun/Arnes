import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// URLSession's data delegate streams on both Darwin and Linux. Keep only the capped
/// prefix, and cancel as soon as one extra byte proves truncation; never buffer the body
/// with data(for:). The lock joins task cancellation with the serial delegate callbacks.
final class BoundedWebFetch: NSObject, URLSessionDataDelegate, @unchecked Sendable {
  private let lock = NSLock()
  private let maxBytes: Int
  private var response = WebFetchResponse(statusCode: 0, headers: [:], body: Data())
  private var continuation: CheckedContinuation<WebFetchResponse, Error>?
  private var session: URLSession?
  private var finished = false

  init(maxBytes: Int) {
    self.maxBytes = max(0, maxBytes)
    super.init()
    response.body.reserveCapacity(min(self.maxBytes, 1 << 20))
  }

  func start(
    _ request: URLRequest, configuration: URLSessionConfiguration,
    continuation: CheckedContinuation<WebFetchResponse, Error>)
  {
    let task: URLSessionDataTask? = lock.withLock {
      guard !finished else { return nil }
      self.continuation = continuation
      let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
      self.session = session
      return session.dataTask(with: request)
    }
    guard let task else {
      continuation.resume(throwing: CancellationError())
      return
    }
    task.resume()
  }

  func cancel() { finish(.failure(CancellationError())) }

  private func finish(_ result: Result<WebFetchResponse, Error>) {
    let pending = lock.withLock { () -> (CheckedContinuation<WebFetchResponse, Error>?, URLSession?)? in
      guard !finished else { return nil }
      finished = true
      defer { continuation = nil; session = nil }
      return (continuation, session)
    }
    guard let (continuation, session) = pending else { return }
    session?.invalidateAndCancel()
    continuation?.resume(with: result)
  }

  func urlSession(
    _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void)
  {
    let active = lock.withLock {
      guard !finished else { return false }
      if let http = response as? HTTPURLResponse {
        self.response.statusCode = http.statusCode
        for (key, value) in http.allHeaderFields {
          if let key = key as? String, let value = value as? String {
            self.response.headers[key] = value
          }
        }
      }
      return true
    }
    completionHandler(active ? .allow : .cancel)
  }

  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
    let capped = lock.withLock { () -> WebFetchResponse? in
      guard !finished else { return nil }
      let remaining = maxBytes - response.body.count
      response.body.append(contentsOf: data.prefix(remaining))
      guard data.count > remaining else { return nil }
      response.truncated = true
      return response
    }
    if let capped { finish(.success(capped)) }
  }

  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    if let error { finish(.failure(error)) }
    else { finish(.success(lock.withLock { response })) }
  }

  func urlSession(
    _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest,
    completionHandler: @escaping @Sendable (URLRequest?) -> Void)
  {
    completionHandler(nil) // Only WebFetchTool may authorize the next host/redirect.
  }
}
