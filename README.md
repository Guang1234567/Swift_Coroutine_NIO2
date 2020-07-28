# Swift_Coroutine_NIO2

The other `Swift Coroutine` library that base on [apple/swift-nio](https://github.com/apple/swift-nio).

Also glance over the brother project to get more info:

[Guang1234567/Swift_Coroutine](https://github.com/Guang1234567/Swift_Coroutine) which base on `GCD`

## Usage

This library can be used in some `web framework` base on [apple/swift-nio](https://github.com/apple/swift-nio):

- [vapor/vapor](https://github.com/vapor/vapor)

- [NozeIO/MicroExpress](https://github.com/NozeIO/MicroExpress)

## NozeIO/MicroExpress

[Example/main.swift](Sources/Example/main.swift)


```swift
app.get("/hello") { req, res, _ in
    //res.send("Hello")

    let eventLoopOfRequest = req._channel.eventLoop

    EventLoopFuture<Void>.coroutine(eventLoop: eventLoopOfRequest, scheduler: eventLoopOfRequest) { co in
        print("workflow - before")

        print("coDelay - start \(Thread.current)")
        let start = CFAbsoluteTimeGetCurrent()
        try co.delay(.milliseconds(2000))
        let end = CFAbsoluteTimeGetCurrent()
        print("coDelay - end \(Thread.current)  in \((end - start) * 1000) ms")

        print("co.delay - Thread.current - \(Thread.current)")

        // switch to IO thread for some expensive work!
        // -----------------------------------------------
        try co.continueOn(threadPool) // change scheduler from `eventLoopOfRequest` to `ioThreadPool`
        print("co.continueOn(threadPool) - Thread.current - \(Thread.current)")
        try co.yield()
        print("co.continueOn(threadPool) after co.yield() - Thread.current - \(Thread.current)")

        // remember switch back to request's eventLoop for `Response # send`,
        // keep in mind that `Request` and `Response` must be running in the same eventloop to ensure the correctness of the timing sequence
        // -----------------------------------------------
        try co.continueOn(eventLoopOfRequest) // switch to IO thread for some expensive work!
        print("co.continueOn(eventLoop) - Thread.current - \(Thread.current)")

        res.send("Hello - delay 2000 ms")

        print("workflow - end")
    }
}
```

browse

```bash
    http://localhost:1337/hello
```

**output**

```ruby
Server running on: [IPv6]::1/::1:1337
GET: /hello
workflow - before
coDelay - start <NSThread: 0x7fc008a0a8e0>{number = 2, name = (null)}
coDelay - end <NSThread: 0x7fc008a0a8e0>{number = 2, name = (null)}  in 2005.2579641342163 ms
co.delay - Thread.current - <NSThread: 0x7fc008a0a8e0>{number = 2, name = (null)}
co.continueOn(threadPool) - Thread.current - <NSThread: 0x7fc007c16b60>{number = 3, name = (null)}
co.continueOn(threadPool) after co.yield() - Thread.current - <NSThread: 0x7fc007e07e60>{number = 4, name = (null)}
co.continueOn(eventLoop) - Thread.current - <NSThread: 0x7fc008a0a8e0>{number = 2, name = (null)}
workflow - end
```


## vapor/vapor

[vapor4_auth_template](https://github.com/Guang1234567/vapor4_auth_template/blob/e8c33a489f3661e22fc9cf3faaa6920f4527fad0/Sources/App/Controllers/UserController.swift#L80-L135)

- `EventLoopFuture` chain async code style

```swift
    func login(req: Request) throws -> EventLoopFuture<UserToken> {
        let user = try req.auth.require(User.self)
        let userTokenBeDeleted = req.auth.get(UserToken.self)


        return req.application.threadPool.runIfActive(eventLoop: req.eventLoop) {
            try user.generateToken()
        }.flatMap { token in
            let saveToken = token.save(on: req.db)
                                 .map {
                                     token
                                 }


            if let userTokenBeDeleted = userTokenBeDeleted {
                return UserToken.query(on: req.db)
                                .filter(\.$value == userTokenBeDeleted.value)
                                .delete(force: true)
                                .flatMap {
                                    saveToken
                                }
            } else {
                return saveToken
            }
        }
    }
```

- `Coroutine` async code style

```swift
func login(req: Request) throws -> EventLoopFuture<UserToken> {

        let user = try req.auth.require(User.self)
        let userTokenBeDeleted = req.auth.get(UserToken.self)

        let eventLoop = req.eventLoop
        let ioThreadPool = req.application.threadPool
        return EventLoopFuture<UserToken>.coroutine(eventLoop: eventLoop, scheduler: eventLoop) { co in

            // change scheduler from `eventLoop` to `ioThreadPool`
            try co.continueOn(ioThreadPool)

            let token = try user.generateToken()

            try co.continueOn(eventLoop)

            if let userTokenBeDeleted = userTokenBeDeleted {
                try UserToken.query(on: req.db)
                             .filter(\.$value == userTokenBeDeleted.value)
                             .delete(force: true)
                             .await(co)
            }

            return try token.save(on: req.db)
                            .map {
                                token
                            }
                            .await(co)
        }
    }
```

More Human readable !

**Code Analysis:**

1. Create a `Coroutine`

```swift
EventLoopFuture<UserToken>.coroutine(eventLoop: eventLoop, scheduler: eventLoop) { co in
    // other code ...
}
```

2. Thread switch

```swift

let eventLoop = req.eventLoop
let ioThreadPool = req.application.threadPool
let globalDispatchQueue = DispatchQueue.global()
let customQueue = DispatchQueue(label: "custom_queue", attributes: .concurrent)

// switch to io thread for some expensive work
// ----------- 
try co.continueOn(ioThreadPool)

// some expensive work here ...

// switch back to the request's eventloop
// ----------- 
try co.continueOn(eventLoop)


// switch back to the GCD's global queue
// ----------- 
try co.continueOn(globalDispatchQueue)

// switch back to the GCD's custom queue
// ----------- 
try co.continueOn(customQueue)

```

3. Obtain `EventLoopFuture`'s result in a **Non-Blocking** way

```swift

let f: EventLoopFuture<UserToken> = token.save(on: req.db).map { token }.await(co)

let token: UserToken = try f.await(co)

retrun token

```
