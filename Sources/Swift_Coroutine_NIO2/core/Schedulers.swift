import Foundation
import NIO

protocol CoroutineScheduler {

    func execute(_ task: @escaping () -> Void) -> Void

    @discardableResult
    func scheduleTask(deadline: NIODeadline, _ task: @escaping () throws -> Void) -> Scheduled<Void>

}

struct EventLoopScheduler: CoroutineScheduler, Equatable {

    private let _eventLoop: EventLoop

    public init(_ eventLoop: EventLoop) { _eventLoop = eventLoop }

    public func execute(_ task: @escaping () -> Void) -> Void {
        _eventLoop.execute(task)
    }

    public func scheduleTask(deadline: NIODeadline, _ task: @escaping () throws -> Void) -> Scheduled<Void> {
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

    public func scheduleTask(deadline: NIODeadline, _ task: @escaping () throws -> Void) -> Scheduled<Void> {
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
