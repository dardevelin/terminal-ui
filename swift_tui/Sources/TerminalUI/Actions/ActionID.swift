/// Stable string-shaped identifier for an `Action`. Lets actions stay
/// addressable across processes — debuggers, MCP clients, the test
/// harness, and serialized command palettes can fire `app.invoke("app.quit")`
/// without depending on closure identity or ObjectIdentifier.
///
/// IDs follow a dotted convention: `app.quit`, `editor.save`,
/// `palette.show`. The leading segment is the owning module; the rest
/// is the action's name. Duplicate IDs in a single scope are a usage
/// bug — the dispatcher fires the first match and reports the
/// duplicate via DebugStream.
public struct ActionID: Hashable, Sendable, ExpressibleByStringLiteral, CustomStringConvertible {
    public let raw: String

    public init(_ raw: String) {
        self.raw = raw
    }

    public init(stringLiteral value: StringLiteralType) {
        self.raw = value
    }

    public var description: String { raw }
}
