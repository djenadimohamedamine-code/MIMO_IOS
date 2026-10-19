import Foundation

/// Runs one bounded capture step per queue turn. Unlike a while-loop on a
/// serial queue, this lets reconnect, quality-change and cleanup work execute.
final class SerialCapturePump {
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var running = false
    private var generation: UInt64 = 0

    init(queue: DispatchQueue) { self.queue = queue }

    var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return running
    }

    func start(step: @escaping () -> TimeInterval) {
        lock.lock()
        guard !running else { lock.unlock(); return }
        running = true
        generation &+= 1
        let token = generation
        lock.unlock()
        schedule(token: token, delay: 0, step: step)
    }

    func stop() {
        lock.lock(); defer { lock.unlock() }
        running = false
        generation &+= 1
    }

    private func isCurrent(_ token: UInt64) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return running && generation == token
    }

    private func schedule(token: UInt64, delay: TimeInterval,
                          step: @escaping () -> TimeInterval) {
        queue.asyncAfter(deadline: .now() + max(0, delay)) { [weak self] in
            guard let self = self, self.isCurrent(token) else { return }
            let nextDelay = step()
            guard self.isCurrent(token) else { return }
            self.schedule(token: token, delay: nextDelay, step: step)
        }
    }
}

/// One in-flight value plus at most one pending value. New arrivals replace
/// the pending value, keeping a live video receiver close to the live edge.
/// Session tokens prevent stopped/restarted work from delivering stale output.
final class LatestValueWorker<Value> {
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var active = false
    private var generation: UInt64 = 0
    private var pending: Value?
    private var scheduled = false

    init(queue: DispatchQueue) { self.queue = queue }

    func start() {
        lock.lock(); defer { lock.unlock() }
        generation &+= 1
        active = true
        pending = nil
        scheduled = false
    }

    func stop() {
        lock.lock(); defer { lock.unlock() }
        generation &+= 1
        active = false
        pending = nil
        scheduled = false
    }

    func isCurrent(_ token: UInt64) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return active && generation == token
    }

    /// Returns true when an older pending value was dropped.
    @discardableResult
    func submit(_ value: Value, consume: @escaping (Value, UInt64) -> Void) -> Bool {
        lock.lock()
        guard active else { lock.unlock(); return false }
        let replaced = pending != nil
        pending = value
        let token = generation
        let needsSchedule = !scheduled
        scheduled = true
        lock.unlock()
        if needsSchedule { schedule(token: token, consume: consume) }
        return replaced
    }

    private func schedule(token: UInt64, consume: @escaping (Value, UInt64) -> Void) {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.lock.lock()
            guard self.active && self.generation == token else {
                self.lock.unlock(); return
            }
            guard let value = self.pending else {
                self.scheduled = false
                self.lock.unlock(); return
            }
            self.pending = nil
            self.lock.unlock()
            consume(value, token)
            self.schedule(token: token, consume: consume)
        }
    }
}
