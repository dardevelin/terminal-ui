#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// A growable byte buffer that writes directly to a file descriptor.
/// Avoids String allocation entirely — works in raw UTF-8 bytes.
/// Reusable across frames to avoid repeated allocation.
public struct OutputBuffer {
    private var bytes: [UInt8]
    private var count: Int

    public init(capacity: Int = 65536) {
        self.bytes = [UInt8](repeating: 0, count: capacity)
        self.count = 0
    }

    /// Number of bytes currently in the buffer
    public var size: Int { count }

    public mutating func reset() {
        count = 0
    }

    // MARK: - Writing raw bytes

    public mutating func write(_ byte: UInt8) {
        ensureCapacity(1)
        bytes[count] = byte
        count += 1
    }

    public mutating func write(_ slice: UnsafeBufferPointer<UInt8>) {
        ensureCapacity(slice.count)
        for i in 0..<slice.count {
            bytes[count + i] = slice[i]
        }
        count += slice.count
    }

    public mutating func write(_ string: StaticString) {
        string.withUTF8Buffer { buf in
            ensureCapacity(buf.count)
            for i in 0..<buf.count {
                bytes[count + i] = buf[i]
            }
            count += buf.count
        }
    }

    /// Write a runtime string's UTF-8 bytes directly
    public mutating func writeString(_ s: String) {
        var s = s
        s.withUTF8 { buf in
            ensureCapacity(buf.count)
            for i in 0..<buf.count {
                bytes[count + i] = buf[i]
            }
            count += buf.count
        }
    }

    // MARK: - ANSI Terminal Control
    //
    // Reference: ECMA-48 (ISO/IEC 6429), xterm ctlseqs.
    // CSI = Control Sequence Introducer: ESC [ (0x1B 0x5B)
    // SGR = Select Graphic Rendition: CSI Ps m
    //   Ps: 0=reset, 1=bold, 3=italic, 4=underline
    //   FG: 30-37 standard, 90-97 bright, 38;5;N 256-color, 38;2;R;G;B truecolor
    //   BG: 40-47 standard, 100-107 bright, 48;5;N 256-color, 48;2;R;G;B truecolor
    // CUP = Cursor Position: CSI row ; col H (1-indexed)

    /// CSI: ESC [ — prefix for all cursor/color/attribute sequences
    public mutating func writeCSI() {
        write(0x1B)  // ESC
        write(0x5B)  // [
    }

    /// Write an integer as ASCII digits
    public mutating func writeInt(_ n: Int) {
        if n == 0 {
            write(0x30) // '0'
            return
        }
        var digits: [UInt8] = []
        var val = n
        while val > 0 {
            digits.append(UInt8(val % 10) + 0x30)
            val /= 10
        }
        ensureCapacity(digits.count)
        for i in stride(from: digits.count - 1, through: 0, by: -1) {
            bytes[count] = digits[i]
            count += 1
        }
    }

    /// ESC[row;colH — cursor position (1-indexed)
    public mutating func writeCursorPosition(row: Int, col: Int) {
        writeCSI()
        writeInt(row)
        write(0x3B) // ';'
        writeInt(col)
        write(0x48) // 'H'
    }

    /// ESC[0m — reset
    public mutating func writeReset() {
        writeCSI()
        write(0x30) // '0'
        write(0x6D) // 'm'
    }

    /// ESC[Nm — single SGR parameter
    public mutating func writeSGR(_ n: Int) {
        writeCSI()
        writeInt(n)
        write(0x6D) // 'm'
    }

    /// Write a character's UTF-8 encoding
    public mutating func writeCharacter(_ char: Character) {
        var s = String(char)
        s.withUTF8 { buf in
            ensureCapacity(buf.count)
            for i in 0..<buf.count {
                bytes[count + i] = buf[i]
            }
            count += buf.count
        }
    }

    /// Write a full style change
    public mutating func writeStyle(_ style: Style) {
        writeReset()
        if let fg = style.foreground {
            writeColorFG(fg)
        }
        if let bg = style.background {
            writeColorBG(bg)
        }
        if style.bold { writeSGR(1) }
        if style.italic { writeSGR(3) }
        if style.underline { writeSGR(4) }
    }

    mutating func writeColorFG(_ color: Color) {
        switch color {
        case .default: writeSGR(39)
        case .black: writeSGR(30)
        case .red: writeSGR(31)
        case .green: writeSGR(32)
        case .yellow: writeSGR(33)
        case .blue: writeSGR(34)
        case .magenta: writeSGR(35)
        case .cyan: writeSGR(36)
        case .white: writeSGR(37)
        case .gray: writeSGR(90)
        case .brightRed: writeSGR(91)
        case .brightGreen: writeSGR(92)
        case .brightYellow: writeSGR(93)
        case .brightBlue: writeSGR(94)
        case .brightMagenta: writeSGR(95)
        case .brightCyan: writeSGR(96)
        case .brightWhite: writeSGR(97)
        case .ansi256(let n):
            writeCSI()
            write(0x33); write(0x38); write(0x3B); write(0x35); write(0x3B) // "38;5;"
            writeInt(Int(n))
            write(0x6D)
        case .rgb(let r, let g, let b):
            writeCSI()
            write(0x33); write(0x38); write(0x3B); write(0x32); write(0x3B) // "38;2;"
            writeInt(Int(r)); write(0x3B)
            writeInt(Int(g)); write(0x3B)
            writeInt(Int(b))
            write(0x6D)
        }
    }

    mutating func writeColorBG(_ color: Color) {
        switch color {
        case .default: writeSGR(49)
        case .black: writeSGR(40)
        case .red: writeSGR(41)
        case .green: writeSGR(42)
        case .yellow: writeSGR(43)
        case .blue: writeSGR(44)
        case .magenta: writeSGR(45)
        case .cyan: writeSGR(46)
        case .white: writeSGR(47)
        case .gray: writeSGR(100)
        case .brightRed: writeSGR(101)
        case .brightGreen: writeSGR(102)
        case .brightYellow: writeSGR(103)
        case .brightBlue: writeSGR(104)
        case .brightMagenta: writeSGR(105)
        case .brightCyan: writeSGR(106)
        case .brightWhite: writeSGR(107)
        case .ansi256(let n):
            writeCSI()
            write(0x34); write(0x38); write(0x3B); write(0x35); write(0x3B) // "48;5;"
            writeInt(Int(n))
            write(0x6D)
        case .rgb(let r, let g, let b):
            writeCSI()
            write(0x34); write(0x38); write(0x3B); write(0x32); write(0x3B) // "48;2;"
            writeInt(Int(r)); write(0x3B)
            writeInt(Int(g)); write(0x3B)
            writeInt(Int(b))
            write(0x6D)
        }
    }

    // MARK: - Flush to file descriptor

    /// Flush the entire buffer in a single POSIX write() syscall.
    ///
    /// One atomic write matters because:
    /// - Minimizes kernel context switches vs N individual print() calls
    /// - Reduces terminal round-trip latency (critical over SSH)
    /// - Prevents partial-frame tearing in the terminal emulator
    ///
    /// Handles partial writes: if write() returns fewer bytes than requested
    /// (e.g. interrupted by a signal), retries with the remaining bytes.
    public func flush(to fd: Int32 = STDOUT_FILENO) {
        bytes.withUnsafeBufferPointer { buf in
            var written = 0
            while written < count {
                let n = posixWrite(fd, buf.baseAddress! + written, count - written)
                if n <= 0 { break }
                written += n
            }
        }
    }

    // MARK: - Internal

    private mutating func ensureCapacity(_ needed: Int) {
        let required = count + needed
        if required <= bytes.count { return }
        var newCap = bytes.count
        while newCap < required { newCap *= 2 }
        var newBuf = [UInt8](repeating: 0, count: newCap)
        newBuf[0..<count] = bytes[0..<count]
        bytes = newBuf
    }
}
