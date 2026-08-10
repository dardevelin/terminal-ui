# ``TerminalUI/GraphContext/$currentFocusEngine``

The `TaskLocal` projection of ``GraphContext/currentFocusEngine``.

The runtime binds its focus engine through
`$currentFocusEngine.withValue(engine) { ... }` around graph updates so focus
modifiers can register as they build; the binding restores itself on closure
exit. Read the plain ``GraphContext/currentFocusEngine`` for the value itself.
