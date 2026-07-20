import Foundation

/// Minimal TOML-subset parser.
/// Supports: `[section]` headers, `key = value` pairs (bool, int, string), `#` comments.
/// No arrays, nested tables, multiline strings, or datetime.
/// Every valid config this parser writes is also valid full-spec TOML.
public enum TOMLParser {

    // MARK: - Parse

    /// Parse a TOML-subset string into `[section: [key: value]]`.
    /// Top-level keys (before any section header) use the empty string as section name.
    public static func parse(_ contents: String) -> [String: [String: String]] {
        var sections: [String: [String: String]] = [:]
        var currentSection = ""

        for line in contents.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty || trimmed.hasPrefix("#") {
                continue
            }

            if trimmed.hasPrefix("["), let close = trimmed.firstIndex(of: "]") {
                let name = trimmed[trimmed.index(after: trimmed.startIndex)..<close]
                currentSection = String(name).trimmingCharacters(in: .whitespaces)
                continue
            }

            guard let eqIndex = trimmed.firstIndex(of: "=") else { continue }

            let key = String(trimmed[trimmed.startIndex..<eqIndex]).trimmingCharacters(in: .whitespaces)
            var value = String(trimmed[trimmed.index(after: eqIndex)...]).trimmingCharacters(in: .whitespaces)

            // Strip optional double quotes
            if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
                value = String(value.dropFirst().dropLast())
            }

            if sections[currentSection] == nil {
                sections[currentSection] = [:]
            }
            sections[currentSection]?[key] = value
        }

        return sections
    }

    // MARK: - Write

    /// Serialize sections back to a TOML string.
    /// Sections and keys are written in sorted order for deterministic output.
    public static func write(_ sections: [String: [String: String]]) -> String {
        var output = ""

        let sortedSections = sections.keys.sorted()
        for (index, section) in sortedSections.enumerated() {
            guard let pairs = sections[section], !pairs.isEmpty else { continue }

            if index > 0 { output += "\n" }

            if !section.isEmpty {
                output += "[\(section)]\n"
            }

            for key in pairs.keys.sorted() {
                if let value = pairs[key] {
                    output += "\(key) = \(formatValue(value))\n"
                }
            }
        }

        return output
    }

    // MARK: - Value formatting

    /// Format a value for TOML output.
    /// Bools and integers are written bare. Everything else is quoted.
    private static func formatValue(_ value: String) -> String {
        if value == "true" || value == "false" {
            return value
        }
        if Int(value) != nil {
            return value
        }
        return "\"\(value)\""
    }
}
