import Foundation
import SwiftAtomics

public enum CoChannelError: Error {
    case closed
}

public class CoChannel<E>: CustomDebugStringConvertible, CustomStringConvertible {

    let _capacity: Int

    let _semFull: CoSemaphore

    let _semEmpty: CoSemaphore

    let _semMutex: CoSemaphore

    var _buffer: [E]

    var _isClosed: AtomicBool

    var _name: String!

    public init(name: String? = nil, capacity: Int = 7) {
        _capacity = capacity
        _semFull = CoSemaphore(value: capacity, "CoChannel_Full")
        _semEmpty = CoSemaphore(value: 0, "CoChannel_Empty")
        _semMutex = CoSemaphore(value: 1, "CoChannel_Mutex")
        _buffer = []
        _isClosed = AtomicBool()
        _isClosed.initialize(false)
        _name = name ?? "\(ObjectIdentifier(self))"
    }

    public func send(_ co: Coroutine, _ e: E) throws -> Void {
        //try _semMutex.wait(co)
        if self.isClosed() {
            //print("\(co) send  close")
            /*defer {
                _semMutex.signal()
            }*/
            throw CoChannelError.closed
        }/* else {
            _semMutex.signal()
        }*/

        defer {
            _semEmpty.signal()
        }
        try _semFull.wait(co)

        try _semMutex.wait(co)
        defer {
            _semMutex.signal()
        }
        _buffer.append(e)
    }

    func _receive(_ co: Coroutine) throws -> E {
        try _semMutex.wait(co)
        if self.isClosed()
           && _buffer.isEmpty {
            //print("\(co) receive  close")
            defer {
                _semMutex.signal()
            }
            throw CoChannelError.closed
        } else {
            _semMutex.signal()
        }

        defer {
            _semFull.signal()
        }
        try _semEmpty.wait(co)

        try _semMutex.wait(co)
        defer {
            _semMutex.signal()
        }
        return _buffer.removeFirst()
    }

    public func receive(_ co: Coroutine) throws -> AnyIterator<E> {
        return AnyIterator { [unowned self] in
            return try? self._receive(co)
        }
    }

    public func close() -> Void {
        if _isClosed.CAS(current: false, future: true) {
        }
    }

    public func isClosed() -> Bool {
        _isClosed.load()
    }

    public var debugDescription: String {
        return description
    }

    public var description: String {
        return """
               CoChannel(
                    _name: \(String(describing: _name)),
                    _isClosed: \(isClosed()),
                    _semFull: \(_semFull),
                    _semEmpty: \(_semEmpty),
                    _semMutex: \(_semMutex),
                    _buffer: \(_buffer)
               )
               """
    }

}