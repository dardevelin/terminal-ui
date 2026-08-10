# ``TerminalUI/GraphContext/$currentNode``

The `TaskLocal` projection of ``GraphContext/currentNode``.

The runtime binds the current node through `$currentNode.withValue(node) { ... }`
around each body evaluation, layout pass, and render walk; the binding restores
itself on closure exit, throw included. Read the plain
``GraphContext/currentNode`` for the value itself.
