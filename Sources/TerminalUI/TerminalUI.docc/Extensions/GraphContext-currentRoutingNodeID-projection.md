# ``TerminalUI/GraphContext/$currentRoutingNodeID``

The `TaskLocal` projection of ``GraphContext/currentRoutingNodeID``.

`FocusEngine` binds the dispatch target through
`$currentRoutingNodeID.withValue(id) { ... }` for the duration of a key
handler's invocation; the binding restores itself on closure exit. Read the
plain ``GraphContext/currentRoutingNodeID`` for the value itself.
