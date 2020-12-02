import Foundation
import NIO
import Swift_Boost_Context
import SwiftAtomics
import RxSwift
import RxBlocking

public enum CoroutineState: Int {
    case INITED = 0
    case STARTED = 1
    case RESTARTED = 2
    case YIELDED = 3
    case EXITED = 4
}

public typealias CoroutineScopeFn<T> = (Coroutine) throws -> T

public typealias CoroutineResumer = () -> Void

public class CoJob {

    var _isCanceled: AtomicBool
    let _co: Coroutine

    public var onStateChanged: Observable<CoroutineState> {
        _co.onStateChanged
    }

    init(_ co: Coroutine) {
        _isCanceled = AtomicBool()
        _isCanceled.initialize(false)
        _co = co
    }

    @discardableResult
    public func cancel() -> Bool {
        // can not cancel Coroutine
        _isCanceled.CAS(current: false, future: true)
    }

    public func join() throws -> Void {
        try _co.onStateChanged.ignoreElements().toBlocking().first()
    }
}

public protocol Coroutine {

    var currentState: CoroutineState { get }

    var onStateChanged: Observable<CoroutineState> { get }

    func yield() throws -> Void

    func yieldUntil(cond: () throws -> Bool) throws -> Void

    func yieldUntil(_ beforeYield: (@escaping CoroutineResumer) -> Void) throws -> Void

    func delay(_ timeInterval: TimeAmount) throws -> Void

    func continueOn(_ scheduler: NIOThreadPool) throws -> Void

    func continueOn(_ scheduler: EventLoop) throws -> Void

    func continueOn(_ scheduler: DispatchQueue) throws -> Void

}

enum CoroutineTransfer<T> {
    case YIELD
    case YIELD_UNTIL(Completable)
    case DELAY(TimeAmount)
    case CONTINUE_ON_SCHEDULER(CoroutineScheduler)
    case EXIT(Result<T, Error>)
}

class CoroutineImpl<T>: Coroutine, CustomDebugStringConvertible, CustomStringConvertible {

    let _name: String

    var _originCtx: FN_YIELD<Void, CoroutineTransfer<T>>!

    var _yieldCtx: FN_YIELD<CoroutineTransfer<T>, Void>!

    var _eventLoop: EventLoop

    var _scheduler: CoroutineScheduler

    let _task: CoroutineScopeFn<T>

    var _currentState: AtomicInt

    let _disposeBag: DisposeBag = DisposeBag()

    let _onStateChanged: AsyncSubject<CoroutineState>

    var currentState: CoroutineState {
        CoroutineState(rawValue: _currentState.load()) ?? .EXITED
    }

    var onStateChanged: Observable<CoroutineState> {
        return _onStateChanged.asObserver()
    }

    deinit {
        _yieldCtx = nil
        _originCtx = nil
        print("CoroutineImpl deinit : _name = \(_name)")
    }

    init(
            _ name: String,
            _ eventLoop: EventLoop,
            _ scheduler: CoroutineScheduler,
            _ task: @escaping CoroutineScopeFn<T>
    ) {
        _name = name
        _onStateChanged = AsyncSubject()
        _eventLoop = eventLoop
        _scheduler = scheduler
        _task = task
        _currentState = AtomicInt()
        _currentState.initialize(CoroutineState.INITED.rawValue)

        // issue: memory leak!
        //originCtx = makeBoostContext(self.coScopeFn)

        _originCtx = makeBoostContext { [unowned self] (data: Void, yieldFn: @escaping FN_YIELD<CoroutineTransfer<T>, Void>) -> CoroutineTransfer<T> in
            return self.coScopeFn(data, yieldFn)
        }
    }

    func triggerStateChangedEvent(_ state: CoroutineState) {
        _onStateChanged.on(.next(state))
        if state == CoroutineState.EXITED {
            _onStateChanged.on(.completed)
        }
    }

    @inline(__always)
    func coScopeFn(_ data: Void, _ yieldFn: @escaping FN_YIELD<CoroutineTransfer<T>, Void>) -> CoroutineTransfer<T> {
        self._yieldCtx = yieldFn

        self._currentState.CAS(current: CoroutineState.INITED.rawValue, future: CoroutineState.STARTED.rawValue)
        self.triggerStateChangedEvent(.STARTED)

        let result: Result<T, Error> = Result { [unowned self] in
            try self._task(self)
        }

        return CoroutineTransfer.EXIT(result)
    }

    func start() -> Void {
        let bctx: FN_YIELD<Void, CoroutineTransfer<T>> = _originCtx
        _scheduler.execute(self.makeResumer(bctx))
    }

    func resume(_ yield: @escaping FN_YIELD<Void, CoroutineTransfer<T>>, ctf: CoroutineTransfer<T>) -> Void {
        switch ctf {
        case .YIELD:
            _scheduler.execute(self.makeResumer(yield))
            triggerStateChangedEvent(.YIELDED)
        case .YIELD_UNTIL(let onJumpBack):
            onJumpBack.subscribe(onCompleted: { [unowned self] in
                        //print("\(self)  --  YIELD_UNTIL2")
                        self._scheduler.execute(self.makeResumer(yield))
                    })
                    .disposed(by: _disposeBag)
            triggerStateChangedEvent(.YIELDED)
        case .DELAY(let timeInterval):
            _scheduler.scheduleTask(deadline: .now() + timeInterval, self.makeResumer(yield))
            triggerStateChangedEvent(.YIELDED)
        case .CONTINUE_ON_SCHEDULER(let scheduler):
            _scheduler = scheduler
            scheduler.execute(self.makeResumer(yield))
            triggerStateChangedEvent(.YIELDED)
        case .EXIT(let result):
            _currentState.store(CoroutineState.EXITED.rawValue)
            triggerStateChangedEvent(.EXITED)

        }
    }

    func makeResumer(_ yield: @escaping FN_YIELD<Void, CoroutineTransfer<T>>) -> CoroutineResumer {
        return { /*[unowned self] in*/
            let coTransfer: CoroutineTransfer<T> = yield(())
            return self.resume(yield, ctf: coTransfer)
        }
    }

    func yield() throws -> Void {
        return try _yield(CoroutineTransfer.YIELD)
    }

    func yieldUntil(cond: () throws -> Bool) throws -> Void {
        while !(try cond()) {
            try self.yield()
        }
    }

    func yieldUntil(_ beforeYield: (@escaping CoroutineResumer) -> Void) throws -> Void {
        let resumeNotifier: AsyncSubject<Never> = AsyncSubject()
        beforeYield({ resumeNotifier.on(.completed) })
        try _yield(CoroutineTransfer.YIELD_UNTIL(resumeNotifier.asCompletable()))
    }

    func delay(_ timeInterval: TimeAmount) throws -> Void {
        try _yield(CoroutineTransfer.DELAY(timeInterval))
    }

    func continueOn(_ scheduler: NIOThreadPool) throws -> Void {
        let sch = NIOThreadPoolScheduler(_eventLoop, scheduler)
        if let s = _scheduler as? NIOThreadPoolScheduler {
            if s != sch {
                try _yield(CoroutineTransfer.CONTINUE_ON_SCHEDULER(sch))
            }
        } else {
            try _yield(CoroutineTransfer.CONTINUE_ON_SCHEDULER(sch))
        }
    }

    func continueOn(_ scheduler: EventLoop) throws -> Void {
        let sch = EventLoopScheduler(scheduler)
        if let s = _scheduler as? EventLoopScheduler {
            if s != sch {
                try _yield(CoroutineTransfer.CONTINUE_ON_SCHEDULER(sch))
            }
        } else {
            try _yield(CoroutineTransfer.CONTINUE_ON_SCHEDULER(sch))
        }
    }

    func continueOn(_ scheduler: DispatchQueue) throws -> Void {
        let sch = DispatchQueueScheduler(scheduler)
        if let s = _scheduler as? DispatchQueueScheduler {
            if s != sch {
                try _yield(CoroutineTransfer.CONTINUE_ON_SCHEDULER(sch))
            }
        } else {
            try _yield(CoroutineTransfer.CONTINUE_ON_SCHEDULER(sch))
        }
    }

    func _yield(_ ctf: CoroutineTransfer<T>) throws -> Void {
        // not in current coroutine scope
        // equals `func isInsideCoroutine() -> Bool`
        // ---------------
        if _yieldCtx == nil {
            throw CoroutineError.calledOutsideCoroutine(reason: "Call `yield()` outside Coroutine")
        }

        // jump back
        // ---------------
        _currentState.store(CoroutineState.YIELDED.rawValue)
        //print("\(self)  _yield  :  \(fromCtx)  <----  \(Thread.current)")
        let _: Void = _yieldCtx(ctf)
        _currentState.store(CoroutineState.RESTARTED.rawValue)
        triggerStateChangedEvent(.RESTARTED)
        //print("\(self)  _yield  :  \(btf.fromContext)  ---->  \(Thread.current)")
    }

    func isInsideCoroutine() -> Bool {
        return _yieldCtx != nil
    }

    var debugDescription: String {
        return "CoroutineImpl(_name: \(_name))"
    }
    var description: String {
        return "CoroutineImpl(_name: \(_name))"
    }

}


public class CoLauncher {

    static func launch<T>(
            name: String = "",
            eventLoop: EventLoop,
            scheduler: CoroutineScheduler,
            _ task: @escaping CoroutineScopeFn<T>
    ) -> CoJob {
        let co: CoroutineImpl = CoroutineImpl<T>(name, eventLoop, scheduler, task)
        co.start()
        return CoJob(co)
    }

    public static func launch<T>(
            name: String = "",
            eventLoop: EventLoop,
            scheduler: EventLoop,
            _ task: @escaping CoroutineScopeFn<T>
    ) -> CoJob {
        CoLauncher.launch(name: name, eventLoop: eventLoop, scheduler: EventLoopScheduler(scheduler), task)
    }

    public static func launch<T>(
            name: String = "",
            eventLoop: EventLoop,
            scheduler: NIOThreadPool,
            _ task: @escaping CoroutineScopeFn<T>
    ) -> CoJob {
        CoLauncher.launch(name: name, eventLoop: eventLoop, scheduler: NIOThreadPoolScheduler(eventLoop, scheduler), task)
    }

}


extension CoroutineImpl: ReactiveCompatible {

}


extension Reactive where Base: CoroutineImpl<Any> {

}