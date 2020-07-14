import XCTest

#if !canImport(ObjectiveC)
public func allTests() -> [XCTestCaseEntry] {
    return [
        testCase(Swift_Coroutine_NIO2Tests.allTests),
    ]
}
#endif
