import Testing
@testable import Python
import CPython

@Suite(.serialized)
@MainActor
struct RefCountTests {
    init() throws { try PyRuntime.initialize() }

    @Test func dynamicMemberLookupDoesNotLeak() throws {
        let sys = PyObject(retaining: try #require(cpy.module("sys")).reference)
        let before = Py_REFCNT(sys.reference)

        for _ in 0..<1000 {
            _ = sys.version
            _ = sys.no_such_attribute
        }

        #expect(Py_REFCNT(sys.reference) == before)
    }

    @Test func attributeItselfIsReleased() throws {
        let sys = PyObject(retaining: try #require(cpy.module("sys")).reference)
        let version = try #require(sys.version)
        let before = Py_REFCNT(version.reference)

        for _ in 0..<1000 { _ = sys.version }

        #expect(Py_REFCNT(version.reference) == before)
    }
}
