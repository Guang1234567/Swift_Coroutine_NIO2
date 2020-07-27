import Foundation
import NIO
import Swift_Boost_Context
import SwiftAtomics
import RxSwift
import RxCocoa
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

    func continueOn(_ nioThreadPool: NIOThreadPool) throws -> Void

    func continueOn(_ eventLoop: EventLoop) throws -> Void

}

enum CoroutineTransfer<T> {
    case YIELD
    case YIELD_UNTIL(Completable)
    case DELAY(TimeAmount)
    case CONTINUE_ON_NIOTHREADPOOL(NIOThreadPool)
    case CONTINUE_ON_EVENTLOOP(EventLoop)
    case EXIT(Result<T, Error>)
}

class CoroutineImpl<T>: Coroutine, CustomDebugStringConvertible, CustomStringConvertible {

    let _name: String

    var _originCtx: BoostContext!

    var _yieldCtx: BoostContext?

    var _eventLoop: EventLoop

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
        _originCtx = nil
        _yieldCtx = nil
        //print("CoroutineImpl deinit : _name = \(_name)")
    }

    init(
            _ name: String,
            _ eventLoop: EventLoop,
            _ task: @escaping CoroutineScopeFn<T>
    ) {
        _name = name
        _onStateChanged = AsyncSubject()
        _yieldCtx = nil
        _eventLoop = eventLoop
        _task = task
        _currentState = AtomicInt()
        _currentState.initialize(CoroutineState.INITED.rawValue)

        // issue: memory leak!
        //self.originCtx = makeBoostContext(self.coScopeFn)

        _originCtx = makeBoostContext { [unowned self] (fromCtx: BoostContext, data: Void) -> Void in
            //print("\(self)  coScopeFn  :  \(fromCtx)  ---->  \(_bctx!)")
            self._currentState.CAS(current: CoroutineState.INITED.rawValue, future: CoroutineState.STARTED.rawValue)
            self.triggerStateChangedEvent(.STARTED)

            self._yieldCtx = fromCtx
            let result: Result<T, Error> = Result { [unowned self] in
                try self._task(self)
            }

            //print("\(self)  coScopeFn  :  \(_fromCtx ?? fromCtx)  <----  ")
            let _: BoostTransfer<Void> = (self._yieldCtx ?? fromCtx).jump(data: CoroutineTransfer.EXIT(result))
            //print("Never jump back to here !!!")
        }
    }

    func triggerStateChangedEvent(_ state: CoroutineState) {
        _onStateChanged.on(.next(state))
        if state == CoroutineState.EXITED {
            _onStateChanged.on(.completed)
        }
    }

    func start() -> Void {
        let bctx: BoostContext = _originCtx
        _eventLoop.execute(self.makeResumer(bctx))
    }

    func resume(_ bctx: BoostContext, ctf: CoroutineTransfer<T>) -> Void {
        switch ctf {
            case .YIELD:
                triggerStateChangedEvent(.YIELDED)
                _eventLoop.execute(self.makeResumer(bctx))
            case .YIELD_UNTIL(let onJumpBack):
                triggerStateChangedEvent(.YIELDED)
                onJumpBack.subscribe(onCompleted: { [unowned self] in
                              //print("\(self)  --  YIELD_UNTIL2")
                              self._eventLoop.execute(self.makeResumer(bctx))
                          })
                          .disposed(by: _disposeBag)
            case .DELAY(let timeInterval):
                triggerStateChangedEvent(.YIELDED)
                _eventLoop.scheduleTask(deadline: .now() + timeInterval, self.makeResumer(bctx))
            case .CONTINUE_ON_NIOTHREADPOOL(let nioThreadPool):
                triggerStateChangedEvent(.YIELDED)
                nioThreadPool.runIfActive(eventLoop: _eventLoop, self.makeResumer(bctx))
            case .CONTINUE_ON_EVENTLOOP(let eventLoop):
                triggerStateChangedEvent(.YIELDED)
                eventLoop.execute(self.makeResumer(bctx))
            case .EXIT(let result):
                _currentState.store(CoroutineState.EXITED.rawValue)
                triggerStateChangedEvent(.EXITED)

        }
    }

    func makeResumer(_ bctx: BoostContext) -> CoroutineResumer {
        return { /*[unowned self] in*/
            let btf: BoostTransfer<CoroutineTransfer<T>> = bctx.jump(data: ())
            let coTransfer: CoroutineTransfer<T> = btf.data
            return self.resume(btf.fromContext, ctf: coTransfer)
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

    func continueOn(_ nioThreadPool: NIOThreadPool) throws {
        try _yield(CoroutineTransfer.CONTINUE_ON_NIOTHREADPOOL(nioThreadPool))
    }

    func continueOn(_ eventLoop: EventLoop) throws {
        try _yield(CoroutineTransfer.CONTINUE_ON_EVENTLOOP(eventLoop))
    }

    func _yield(_ ctf: CoroutineTransfer<T>) throws -> Void {
        // not in current coroutine scope
        // equals `func isInsideCoroutine() -> Bool`
        // ---------------
        guard let yieldCtx = _yieldCtx else {
            throw CoroutineError.calledOutsideCoroutine(reason: "Call `yield()` outside Coroutine")
        }

        // jump back
        // ---------------
        _currentState.store(CoroutineState.YIELDED.rawValue)
        //print("\(self)  _yield  :  \(fromCtx)  <----  \(Thread.current)")
        let btf: BoostTransfer<Void> = yieldCtx.jump(data: ctf)
        // update `_fromCtx` when restart
        _yieldCtx = btf.fromContext
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

    public static func launch<T>(
            name: String = "",
            eventLoop: EventLoop,
            _ task: @escaping CoroutineScopeFn<T>
    ) -> CoJob {
        let co: CoroutineImpl = CoroutineImpl<T>(name, eventLoop, task)
        co.start()
        return CoJob(co)
    }

}


extension CoroutineImpl: ReactiveCompatible {

}


extension Reactive where Base: CoroutineImpl<Any> {

}