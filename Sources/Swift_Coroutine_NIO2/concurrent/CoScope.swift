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
    public func launch<T>(
            name: String = "",
            eventLoop: EventLoop,
            _ task: @escaping CoroutineScopeFn<T>
    ) -> CoJob {
        let coJob = CoLauncher.launch(name: name, eventLoop: eventLoop, task)
        _coJobs.append(coJob)
        return coJob
    }
}
