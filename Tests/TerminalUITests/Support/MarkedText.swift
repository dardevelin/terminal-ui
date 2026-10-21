/// Text with its cursor written in as `|`, as the editing tests state their
/// cases: `"alpha be|ta"` is "alpha beta" with the cursor before the "t".
enum MarkedText {
    static func split(_ marked: String) -> (text: String, cursor: Int) {
        var characters = Array(marked)
        let cursor = characters.firstIndex(of: "|")!
        characters.remove(at: cursor)
        return (String(characters), cursor)
    }

    static func mark(_ text: some Sequence<Character>, cursor: Int) -> String {
        var characters = Array(text)
        characters.insert("|", at: min(cursor, characters.count))
        return String(characters)
    }
}
