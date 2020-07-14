import Foundation
import NIO
import Swift_Boost_Context
import SwiftAtomics
import RxSwift
import RxCocoa
import RxBlocking

struct Swift_Coroutine_NIO2 {
    var text = "Hello, World!"
}

public extension EventLoopFuture {

    public static func coroutine(_ eventLoop: EventLoop, _ body: @escaping (Coroutine) throws -> Value) -> EventLoopFuture<Value> {
        let promise = eventLoop.makePromise(of: Value.self)
        let _ = CoLauncher.launch(name: "EventLoopFuture#Coroutine", eventLoop: eventLoop) {
            (co: Coroutine) throws -> Void in
            do {
                try promise.succeed(body(co))
            } catch {
                promise.fail(error)
            }
        }
        return promise.futureResult
    }

    public func await(file: StaticString = #file,
                      line: UInt = #line,
                      _ co: Coroutine) throws -> Value {
        var result: Result<Value, Error>? = nil

        try co.yieldUntil { [unowned self] (resumer: @escaping CoroutineResumer) -> Void in

            self.always { r in
                result = r
                resumer()
            }
        }

        return try result!.get()
    }
}