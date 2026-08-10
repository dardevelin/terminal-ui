# ``TerminalUI/GraphContext/$currentProposedSize``

The `TaskLocal` projection of ``GraphContext/currentProposedSize``.

Measurement and layout passes bind the size proposal through
`$currentProposedSize.withValue(size) { ... }` around the subtree they are
sizing; the binding restores itself on closure exit. Read the plain
``GraphContext/currentProposedSize`` for the value itself.
