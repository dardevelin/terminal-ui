# Editing keys

Every text input edits the same way, from one keymap an app can change and,
if it chooses, its users can too.

## Overview

``TextInput``, ``TextArea`` and ``PromptInput`` share one set of named
editing commands — ``TextEditCommand`` — and one engine that performs them. A
``TextKeymap`` says which key performs which, as an Emacs keymap or Cocoa's
`DefaultKeyBinding.dict` does: the commands are named apart from the keys, so
the same command can sit on several keys, and a key can be rebound without
touching the input.

``TextKeymap/standard`` holds readline's keys, which Claude Code, Codex and
Crush follow: Ctrl+A and Ctrl+E for the line's ends, Alt+B and Alt+F by word,
Ctrl+K and Ctrl+U to kill to either end of the line, Ctrl+W back to
whitespace, Ctrl+Y to yank, Ctrl+Z and Ctrl+Shift+Z to undo and redo. These
are also what macOS terminals send for Command and Option chords — Ghostty,
iTerm2 and Terminal.app send Cmd+Left as Ctrl+A and Option+Left as Alt+B —
so the Mac chords work with no binding of their own. A terminal never sends
the Command key itself to an app.

`swtui keys` lists every command with its standard keys.

### A key tries its commands in order

A key binds an ordered list of commands, and the focused input performs the
first that means something to it, as a key goes up Cocoa's responder chain.
Enter is `[.submit, .insertNewline]`: a prompt sends, an editor starts a new
line, and a single-line field, which performs neither, leaves Enter to the
app. Up is `[.moveUp, .previousHistory]`: a prompt moves up a row while there
is one, then into its history. A key whose commands have nothing to do — Ctrl+D
on an empty line — passes on to the app.

### Rebinding keys in an app

An app changes keys for a subtree with ``TerminalView/textKeymap(_:)``,
building on the standard keymap:

```swift
PromptInput(text: $draft)
    .textKeymap(.standard.merging([
        .keyboard(.enter, []): [.insertNewline],   // Enter: a new line
        .keyboard(.enter, .shift): [.submit],      // Shift+Enter: send
        .keyboard(.character("p"), .ctrl): [],     // Ctrl+P: the app's own
    ]))
```

An empty list unbinds a key, so the app's own handlers receive it. Commands
are open names, like ``ActionID``: a keymap in code can bind a name the
framework does not declare, and an input passes over a command it does not
perform. A user's file binds the framework's commands,
``TextEditCommand/declared``.

### Letting users rebind keys

An app can let its users keep their own bindings in a file, laid over the
app's keymap. It opts in, and says where the file lives:

```swift
@main
struct Coder: TerminalAppProtocol {
    static var userKeymap: UserKeymapSource { .configFile(named: "coder") }
    // ~/.config/coder/keys.toml, or under $XDG_CONFIG_HOME
}
```

`.file(at:)` names any other location. The default, `.none`, reads no file.
The file is TOML, keys written as a person writes them:

```toml
[text]
"ctrl+o"      = "deleteToLineEnd"
"enter"       = ["insertNewline"]
"shift+enter" = ["submit"]
"ctrl+w"      = []                # unbind
```

It is read once, before the app takes the terminal. A line that cannot be
read is printed to stderr with its line number, and the rest of the file
still applies; `swtui keys --check <file>` reads a file the same way. Once
the app has the screen stderr is hidden, so an app can show the problems
itself, from `@TerminalEnvironment(\.userKeymap)` and its
``UserKeymap/problems``. A subtree whose keys the app must own turns the
user's bindings off with ``TerminalView/allowsUserKeymap(_:)``.

Keys are written the same way everywhere the framework names them — a
user's `keys.toml`, the debug keybindings in `terminalui.toml`, `swtui bind`
and the remote control's `send-key`: modifiers `ctrl`, `alt` (or `option`,
`meta`) and `shift`, and a key that is one character, `F1` to `F24`, or a
name such as `enter`, `backspace`, `pagedown` or `space`.

## Topics

- ``TextEditCommand``
- ``TextKeymap``
- ``UserKeymap``
- ``UserKeymapSource``
- ``KillBuffer``
