import Foundation
import NIO

protocol CoroutineScheduler {

    func execute(_ task: @escaping () -> Void) -> Void

    @discardableResult
    func scheduleTask(deadline: NIODeadline, _ task: @escaping () -> Void) -> Void

}

struct EventLoopScheduler: CoroutineScheduler, Equatable {

    private let _eventLoop: EventLoop

    public init(_ eventLoop: EventLoop) { _eventLoop = eventLoop }

    public func execute(_ task: @escaping () -> Void) -> Void {
        _eventLoop.execute(task)
    }

    public func scheduleTask(deadline: NIODeadline, _ task: @escaping () -> Void) -> Void {
        _eventLoop.scheduleTask(deadline: deadline, task)
    }

    static func ==(lhs: EventLoopScheduler, rhs: EventLoopScheduler) -> Bool {
        if lhs._eventLoop !== rhs._eventLoop {
            return false
        }
        if type(of: lhs) != type(of: rhs) {
            return false
        }

        return true
    }
}

struct NIOThreadPoolScheduler: CoroutineScheduler, Equatable {

    private let _eventLoop: EventLoop

    private let _nioThreadPool: NIOThreadPool

    public init(_ eventLoop: EventLoop, _ nioThreadPool: NIOThreadPool) {
        _eventLoop = eventLoop
        _nioThreadPool = nioThreadPool
    }

    public func execute(_ task: @escaping () -> Void) {
        _nioThreadPool.runIfActive(eventLoop: _eventLoop, task)
    }

    public func scheduleTask(deadline: NIODeadline, _ task: @escaping () -> Void) -> Void {
        _eventLoop.scheduleTask(deadline: deadline) {
            self._nioThreadPool.runIfActive(eventLoop: self._eventLoop, task)
        }
    }

    static func ==(lhs: NIOThreadPoolScheduler, rhs: NIOThreadPoolScheduler) -> Bool {
        if lhs._eventLoop !== rhs._eventLoop {
            return false
        }

        if lhs._nioThreadPool !== rhs._nioThreadPool {
            return false
        }

        if type(of: lhs) != type(of: rhs) {
            return false
        }

        return true
    }
}

struct DispatchQueueScheduler: CoroutineScheduler, Equatable {

    private let _dispatchQueue: DispatchQueue

    private let _qos: DispatchQoS

    private let _flags: DispatchWorkItemFlags

    public init(_ dispatchQueue: DispatchQueue, qos: DispatchQoS = .unspecified, flags: DispatchWorkItemFlags = []) {
        _dispatchQueue = dispatchQueue
        _qos = qos
        _flags = flags
    }

    public func execute(_ task: @escaping () -> Void) -> Void {
        _dispatchQueue.async(execute: task)
    }

    public func scheduleTask(deadline: NIODeadline, _ task: @escaping () -> Void) -> Void {
        _dispatchQueue.asyncAfter(deadline: DispatchTime(uptimeNanoseconds: deadline.uptimeNanoseconds), qos: _qos, flags: _flags, execute: task)
    }

    static func ==(lhs: DispatchQueueScheduler, rhs: DispatchQueueScheduler) -> Bool {
        if lhs._dispatchQueue !== rhs._dispatchQueue {
            return false
        }
        if lhs._qos != rhs._qos {
            return false
        }
        if lhs._flags != rhs._flags {
            return false
        }
        if type(of: lhs) != type(of: rhs) {
            return false
        }

        return true
    }
}
