public struct Rect: Equatable, Sendable {
    public var x: Int
    public var y: Int
    public var width: Int
    public var height: Int

    public init(x: Int, y: Int, width: Int, height: Int) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var isEmpty: Bool { width <= 0 || height <= 0 }

    public func inset(by amount: Int) -> Rect {
        Rect(
            x: x + amount,
            y: y + amount,
            width: max(0, width - amount * 2),
            height: max(0, height - amount * 2)
        )
    }
}
