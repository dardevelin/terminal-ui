public struct Text: TerminalView {
    public let content: String

    public init(_ content: String) {
        self.content = content
    }

    public var body: Never { fatalError() }
}
