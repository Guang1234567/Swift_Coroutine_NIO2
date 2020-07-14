import Foundation

public enum CoroutineError: Error {

    case canceled(reason: String)

    case calledOutsideCoroutine(reason: String)
}
