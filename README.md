# Swift_Coroutine_NIO2

The other `Swift Coroutine` library that base on [apple/swift-nio](https://github.com/apple/swift-nio).

Also see:

[Guang1234567/Swift_Coroutine](https://github.com/Guang1234567/Swift_Coroutine) which base on `GCD`

## Usage

This library can be used in some `web framework` base on [apple/swift-nio](https://github.com/apple/swift-nio):

- [vapor/vapor](https://github.com/vapor/vapor)

- [NozeIO/MicroExpress](https://github.com/NozeIO/MicroExpress)

## NozeIO/MicroExpress

[Example/main.swift](Sources/Example/main.swift)


```swift
app.get("/hello") { req, res, _ in
    let eventLoopOfRequest = req._channel.eventLoop

    EventLoopFuture<Void>.coroutine(eventLoopOfRequest) { (co) in
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
```



browse

```bash
    http://localhost:1337/hello
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
        return EventLoopFuture<UserToken>.coroutine(eventLoop) { co in

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
EventLoopFuture<UserToken>.coroutine(eventLoop) { co in
    // other code ...
}
```

2. Thread switch

```swift

let eventLoop = req.eventLoop
let ioThreadPool = req.application.threadPool

// switch to io thread for some expensive work
// ----------- 
try co.continueOn(ioThreadPool)

// some expensive work here ...

// switch back to the request's eventloop
// ----------- 
try co.continueOn(eventLoop)

```

3. Obtain `EventLoopFuture`'s result in **Non-Blocking** way

```swift

let f: EventLoopFuture<UserToken> = token.save(on: req.db).map { token }.await(co)

let token: UserToken = try f.await(co)

retrun token

```
