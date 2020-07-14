import Foundation
import Swift_Express
import NIO
import Swift_Coroutine_NIO2


let threadPool: NIOThreadPool = {
    let tp = NIOThreadPool(numberOfThreads: System.coreCount)
    tp.start()
    return tp
}()

let app = Express()

// Logging
app.use { req, res, next in
    print("\(req.header.method):", req.header.uri)
    next() // continue processing
}

app.use(querystring, cors(allowOrigin: "*")) // parse query params

app.get("/hello") { req, res, _ in
    //res.send("Hello")

    let eventLoopOfRequest = req._channel.eventLoop

    EventLoopFuture<Void>.coroutine(eventLoopOfRequest) { co in
        print("workflow - before")

        print("coDelay - start \(Thread.current)")
        let start = CFAbsoluteTimeGetCurrent()
        try co.delay(.milliseconds(2000))
        let end = CFAbsoluteTimeGetCurrent()
        print("coDelay - end \(Thread.current)  in \((end - start) * 1000) ms")

        print("co.delay - Thread.current - \(Thread.current)")

        // switch to IO thread for some expensive work!
        // -----------------------------------------------
        try co.continueOn(threadPool)
        print("co.continueOn(threadPool) - Thread.current - \(Thread.current)")

        // remember switch back to request's eventLoop for `Response # send`,
        // keep in mind that `Request` and `Response` must be running in the same eventloop to ensure the correctness of the timing sequence
        // -----------------------------------------------
        try co.continueOn(eventLoopOfRequest) // switch to IO thread for some expensive work!
        print("co.continueOn(eventLoop) - Thread.current - \(Thread.current)")

        res.send("Hello - delay 2000 ms")

        print("workflow - end")
    }
}

app.get("/moo") { _, res, _ in
    res.send("Moo!")
}

app.get("/todomvc") { _, res, _ in
    // send JSON to the browser
    res.json(todos)
}

app.get { req, res, _ in
    let text = req.param("text")
               ?? "Schwifty"
    res.send("Hello, \(text) world!")
}

app.listen(1337)