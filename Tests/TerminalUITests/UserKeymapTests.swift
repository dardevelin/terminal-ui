import Foundation
import Testing
@testable import TerminalUI

// A user rebinds editing keys in a file of their own, if the app lets them:
// the app opts in and says where the file lives. What the file states lands
// on top of the app's keymap, and its mistakes are pointed at by line rather
// than taking the file down.

@Suite("UserKeymap — a user's bindings, read from TOML")
struct UserKeymapTests {

    @Test("A key binds one command, a list, or none")
    func bindings() {
        let file = UserKeymap(toml: """
        [text]
        "ctrl+o" = "deleteToLineEnd"
        "enter" = ["insertNewline"]
        "shift+enter" = ["submit"]
        "ctrl+w" = []
        """)
        #expect(file.problems.isEmpty)
        #expect(file.text[.keyboard(.character("o"), .ctrl)] == [.deleteToLineEnd])
        #expect(file.text[.keyboard(.enter, [])] == [.insertNewline])
        #expect(file.text[.keyboard(.enter, .shift)] == [.submit])
        #expect(file.text[.keyboard(.character("w"), .ctrl)] == [])
    }

    @Test("Mistakes are reported by line; the rest of the file still binds")
    func problems() {
        let file = UserKeymap(toml: """
        [text]
        "ctl+k" = "deleteToLineEnd"
        "ctrl+k" = "deleteToLineENd"
        "cmd+left" = "moveToLineStart"
        "ctrl+o" = 3
        "ctrl+e" = "moveToLineEnd"
        [colors]
        accent = "red"
        """)
        #expect(file.problems.map(\.line) == [2, 3, 4, 5, 8])
        #expect(file.text.keys.map(\.keySpec) == ["ctrl+e"])
        #expect(file.problems[1].message.contains("moveToLineEnd"),
                "an unknown command lists the commands there are")
    }

    @Test("An unknown section is one problem, however many lines it holds")
    func unknownSection() {
        let file = UserKeymap(toml: "[actions]\n\"ctrl+o\" = \"open\"\n\"ctrl+p\" = \"palette\"")
        #expect(file.problems.map(\.line) == [2])
        #expect(file.problems.first?.message.contains("[text]") == true)
    }

    @Test("Bytes that are not UTF-8 spoil their line, not the file")
    func notUTF8() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("keys-\(UUID()).toml")
        var data = Data("[text]\n\"ctrl+o\" = \"deleteToLineEnd\"\n\"ctrl+y\" = \"ya".utf8)
        data.append(0xFF)
        data.append(contentsOf: Data("nk\"\n".utf8))
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let file = try #require(UserKeymap(contentsOf: url))
        #expect(file.text[.keyboard(.character("o"), .ctrl)] == [.deleteToLineEnd])
        #expect(file.problems.map(\.line) == [3])
    }

    @Test("No file is no bindings and no problems: the user has not made one")
    func missingFile() {
        #expect(UserKeymap(contentsOf: URL(fileURLWithPath: "/nonexistent/keys.toml")) == nil)
    }

    // An input reads its editing context every time its body runs, and the
    // environment compares what it read byte for byte to know nothing
    // changed. A keymap merged afresh on each read had new storage every
    // time, so every input re-ran on every frame once a user file loaded.
    @Test("Reading the editing context twice reads the same value, with or without a user's file")
    func stableAcrossReads() {
        var environment = EnvironmentValues()
        #expect(AttributeGraph.sameEnvironmentValue(environment.textEditing, environment.textEditing))
        environment.userKeymap = UserKeymap(toml: "[text]\n\"ctrl+o\" = \"deleteToLineEnd\"")
        #expect(AttributeGraph.sameEnvironmentValue(environment.textEditing, environment.textEditing))
        #expect(AttributeGraph.sameEnvironmentValue(environment.boundaryHit, environment.boundaryHit))
    }

    @Test("The file's bindings land on top of the app's keymap, unless a subtree locks them out")
    func layering() {
        var environment = EnvironmentValues()
        environment.textKeymap = .standard.merging([.keyboard(.character("y"), .ctrl): [.redo]])
        environment.userKeymap = UserKeymap(toml: "[text]\n\"ctrl+k\" = []")
        let keymap = environment.textEditing.keymap
        #expect(keymap.commands(for: KeyEvent(key: .character("k"), modifiers: .ctrl)).isEmpty)
        #expect(keymap.commands(for: KeyEvent(key: .character("y"), modifiers: .ctrl)) == [.redo])
        environment.allowsUserKeymap = false
        #expect(environment.textEditing.keymap.commands(for: KeyEvent(key: .character("k"), modifiers: .ctrl))
                == [.deleteToLineEnd])
    }
}

@Suite("UserKeymapSource — where an app's users keep their keys")
struct UserKeymapSourceTests {

    @Test("A named file lives in the user's config directory")
    func named() {
        let source = UserKeymapSource.configFile(named: "coder")
        #expect(source.url(environment: ["XDG_CONFIG_HOME": "/cfg", "HOME": "/home/u"])?.path
                == "/cfg/coder/keys.toml")
        #expect(source.url(environment: ["HOME": "/home/u"])?.path == "/home/u/.config/coder/keys.toml")
    }

    @Test("An app can name the file itself, or read none")
    func explicit() {
        #expect(UserKeymapSource.file(at: URL(fileURLWithPath: "/etc/app/keys.toml")).url(environment: [:])?.path
                == "/etc/app/keys.toml")
        #expect(UserKeymapSource.none.url(environment: ["HOME": "/home/u"]) == nil)
    }
}
