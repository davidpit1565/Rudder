import Foundation
#if canImport(Network)
import Network
#endif

/// Knows whether a new decision is even possible right now, so the app can say so
/// up front instead of failing halfway through.
///
/// Reads are lock-protected so the decision pipeline can check connectivity from
/// any context, and `updates` lets the UI react to a change rather than showing
/// whatever was true when the view was first drawn.
///
/// Wrapped behind `canImport(Network)` so the pipeline builds and tests on any
/// platform, not only Apple's.
public final class Reachability: @unchecked Sendable {
    public static let shared = Reachability()

    private let lock = NSLock()
    private var _isConnected = true
    private var continuations: [UUID: AsyncStream<Bool>.Continuation] = [:]

    public var isConnected: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _isConnected
    }

    /// Yields the current value immediately, then every change.
    public var updates: AsyncStream<Bool> {
        AsyncStream { continuation in
            let id = UUID()
            lock.lock()
            continuations[id] = continuation
            let current = _isConnected
            lock.unlock()

            continuation.yield(current)
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                lock.lock()
                continuations[id] = nil
                lock.unlock()
            }
        }
    }

    #if canImport(Network)
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.decide.reachability")
    #endif

    private init() {
        #if canImport(Network)
        monitor.pathUpdateHandler = { [weak self] path in
            self?.update(path.status == .satisfied)
        }
        monitor.start(queue: queue)
        #endif
    }

    private func update(_ connected: Bool) {
        lock.lock()
        guard _isConnected != connected else {
            lock.unlock()
            return
        }
        _isConnected = connected
        let listeners = Array(continuations.values)
        lock.unlock()

        for listener in listeners {
            listener.yield(connected)
        }
    }

    /// Test seam: drives the value the way the network monitor would.
    func simulate(connected: Bool) {
        update(connected)
    }
}
