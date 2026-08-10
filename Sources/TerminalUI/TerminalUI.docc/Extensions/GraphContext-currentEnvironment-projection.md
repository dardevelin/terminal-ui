# ``TerminalUI/GraphContext/$currentEnvironment``

The `TaskLocal` projection of ``GraphContext/currentEnvironment``.

Environment-setting modifiers rebind the value through
`$currentEnvironment.withValue(newEnv) { ... }` around their subtree, so an
override is scoped exactly to the closure and siblings observe their own
settings. Read the plain ``GraphContext/currentEnvironment`` for the value.
