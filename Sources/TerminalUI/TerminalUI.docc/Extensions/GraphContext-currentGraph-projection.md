# ``TerminalUI/GraphContext/$currentGraph``

The `TaskLocal` projection of ``GraphContext/currentGraph``.

The runtime binds the owning graph through `$currentGraph.withValue(graph) { ... }`
for the duration of an update or render; the binding restores itself on closure
exit. Read the plain ``GraphContext/currentGraph`` for the value itself.
