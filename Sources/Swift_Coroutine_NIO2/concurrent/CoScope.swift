import Foundation
import SwiftAtomics
import NIO

open class CoScope {

    var _coJobs: [CoJob]

    var _isCanceled: AtomicBool

    deinit {
        // auto
        cancel()
    }

    init() {
        _coJobs = []
        _isCanceled = AtomicBool()
        _isCanceled.initialize(false)
    }

    @discardableResult
    public final func cancel() -> Bool {
        let r = _isCanceled.CAS(current: false, future: true)
        if r {
            for job in _coJobs {
                job.cancel()
            }
        }
        return r
    }
}

extension CoScope {
    func launch<T>(
            name: String = "",
            eventLoop: EventLoop,
            scheduler: CoroutineScheduler,
            _ task: @escaping CoroutineScopeFn<T>
    ) -> CoJob {
        let coJob = CoLauncher.launch(name: name, eventLoop: eventLoop, scheduler: scheduler, task)
        _coJobs.append(coJob)
        return coJob
    }

    public func launch<T>(
            name: String = "",
            eventLoop: EventLoop,
            scheduler: EventLoop,
            _ task: @escaping CoroutineScopeFn<T>
    ) -> CoJob {
        launch(name: name, eventLoop: eventLoop, scheduler: EventLoopScheduler(scheduler), task)
    }

    public func launch<T>(
            name: String = "",
            eventLoop: EventLoop,
            scheduler: NIOThreadPool,
            _ task: @escaping CoroutineScopeFn<T>
    ) -> CoJob {
        launch(name: name, eventLoop: eventLoop, scheduler: NIOThreadPoolScheduler(eventLoop, scheduler), task)
    }
}
