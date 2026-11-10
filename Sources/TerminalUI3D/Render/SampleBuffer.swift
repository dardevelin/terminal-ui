/// A block of plain values — floats, small integers — kept from frame to
/// frame and written through a raw pointer, so the rasterizer's inner loops
/// neither check bounds nor trigger a copy-on-write test per sample.
///
/// Holds only trivial types, so it never runs a deinitializer per element;
/// its owner indexes inside ``count``.
final class SampleBuffer<Element> {
    private(set) var pointer: UnsafeMutablePointer<Element>
    private(set) var count: Int
    private var capacity: Int

    init(_ value: Element) {
        precondition(_isPOD(Element.self), "a sample buffer holds plain values")
        pointer = .allocate(capacity: 1)
        pointer.initialize(to: value)
        count = 0
        capacity = 1
    }

    deinit {
        pointer.deallocate()
    }

    /// Make room for `count` values, keeping the storage when it is large
    /// enough already, and set every one to `value`.
    func reset(count: Int, to value: Element) {
        if count > capacity {
            pointer.deallocate()
            pointer = .allocate(capacity: count)
            capacity = count
        }
        self.count = count
        pointer.update(repeating: value, count: count)
    }

    @inline(__always)
    subscript(index: Int) -> Element {
        get { pointer[index] }
        set { pointer[index] = newValue }
    }
}
