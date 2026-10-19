import Foundation

@main
struct StreamSchedulingTests {
    static func wait(_ semaphore: DispatchSemaphore, _ message: String) {
        precondition(semaphore.wait(timeout: .now() + 3) == .success, message)
    }

    static func main() {
        // Execute the real production pump, with a deliberately blocked frame.
        let queue = DispatchQueue(label: "test.capture")
        let pump = SerialCapturePump(queue: queue)
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let reconfigured = DispatchSemaphore(value: 0)
        var captures = 0
        pump.start {
            captures += 1
            if captures == 1 { entered.signal(); release.wait() }
            return 0.001
        }
        wait(entered, "capture did not start")
        queue.async { reconfigured.signal() }
        release.signal()
        wait(reconfigured, "quality/reconnect command starved behind capture")
        pump.stop()
        let stoppedCount = queue.sync { captures }
        let afterStop = DispatchSemaphore(value: 0)
        queue.asyncAfter(deadline: .now() + 0.05) {
            precondition(captures == stoppedCount, "capture continued after stop")
            afterStop.signal()
        }
        wait(afterStop, "stop verification failed")
        print("PASS: capture yields to reconnect/quality and stops")

        let blockedQueue = DispatchQueue(label: "test.restart")
        let blocked = DispatchSemaphore(value: 0)
        let unblock = DispatchSemaphore(value: 0)
        blockedQueue.async { blocked.signal(); unblock.wait() }
        wait(blocked, "queue did not block")
        let restarting = SerialCapturePump(queue: blockedQueue)
        var oldSteps = 0
        let newStep = DispatchSemaphore(value: 0)
        restarting.start { oldSteps += 1; return 1 }
        restarting.stop()
        restarting.start { newStep.signal(); return 1 }
        unblock.signal()
        wait(newStep, "pump failed to restart")
        restarting.stop()
        blockedQueue.sync { precondition(oldSteps == 0, "stale session ran after restart") }
        print("PASS: stale capture steps are rejected after restart")

        let decodeQueue = DispatchQueue(label: "test.decode")
        let worker = LatestValueWorker<Int>(queue: decodeQueue)
        worker.start()
        let first = DispatchSemaphore(value: 0)
        let allowDecode = DispatchSemaphore(value: 0)
        let latest = DispatchSemaphore(value: 0)
        var values = [Int]()
        let consume: (Int, UInt64) -> Void = { value, _ in
            values.append(value)
            if value == 1 { first.signal(); allowDecode.wait() }
            if value == 1000 { latest.signal() }
        }
        worker.submit(1, consume: consume)
        wait(first, "first decode did not start")
        var replaced = 0
        for value in 2...1000 {
            if worker.submit(value, consume: consume) { replaced += 1 }
        }
        precondition(replaced == 998, "worker did not replace pending video")
        allowDecode.signal()
        wait(latest, "latest live frame was not decoded")
        decodeQueue.sync { precondition(values == [1, 1000], "video backlog was not bounded") }
        worker.stop()
        print("PASS: 1000 incoming frames retain only in-flight + latest")

        let sessionQueue = DispatchQueue(label: "test.sessions")
        let sessionWorker = LatestValueWorker<Int>(queue: sessionQueue)
        let oldEntered = DispatchSemaphore(value: 0)
        let oldRelease = DispatchSemaphore(value: 0)
        let newDelivered = DispatchSemaphore(value: 0)
        var delivered = [Int]()
        let deliver: (Int, UInt64) -> Void = { value, token in
            if value == 1 { oldEntered.signal(); oldRelease.wait() }
            if sessionWorker.isCurrent(token) {
                delivered.append(value)
                if value == 3 { newDelivered.signal() }
            }
        }
        sessionWorker.start()
        sessionWorker.submit(1, consume: deliver)
        wait(oldEntered, "old session did not start")
        sessionWorker.submit(2, consume: deliver)
        sessionWorker.stop()
        sessionWorker.start()
        sessionWorker.submit(3, consume: deliver)
        oldRelease.signal()
        wait(newDelivered, "new session did not deliver")
        sessionQueue.sync { precondition(delivered == [3], "old session leaked frames") }
        sessionWorker.stop()
        print("PASS: stop discards pending work and invalidates in-flight output")
    }
}
