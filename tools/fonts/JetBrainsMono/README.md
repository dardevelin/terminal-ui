# JetBrains Mono

JetBrains Mono **v2.304**, the four TrueType files the documentation media
are drawn with, unmodified:

- Source: <https://github.com/JetBrains/JetBrainsMono>, tag `v2.304`
  (commit `cd5227bd1f61dff3bbd6c814ceaf7ffd95e947d9`), `fonts/ttf/` and
  `OFL.txt`
- Copyright 2020 The JetBrains Mono Project Authors
- Licence: SIL Open Font License, Version 1.1 — [`OFL.txt`](OFL.txt)

The font is used only by developer tooling, to draw documentation pictures
reproducibly on any system; it is part of no library product. Pictures
drawn with it carry no obligation.

| File | Bytes | SHA-256 |
|------|------:|---------|
| `JetBrainsMono-Regular.ttf` | 273900 | `a0bf60ef0f83c5ed4d7a75d45838548b1f6873372dfac88f71804491898d138f` |
| `JetBrainsMono-Bold.ttf` | 277828 | `5590990c82e097397517f275f430af4546e1c45cff408bde4255dad142479dcb` |
| `JetBrainsMono-Italic.ttf` | 276840 | `9d0a1f7a708e6af183f1193b7e81d40da294f5c67682c085d8401c60aac8ded4` |
| `JetBrainsMono-BoldItalic.ttf` | 279832 | `4039d5ce0ed225bf9c8b2c8c6436290ae2f356b7e90d70fa666227238324aa3b` |
| `OFL.txt` | 4399 | `30f0c136e3c88e422d0791acd97238870f9054a9729bc34cf2ff0d4ed8cac4ad` |

`tools/tests/test_bundled_font.py` checks every file against this table,
and that nothing else is here. Changing the font means replacing the files
from a release, updating this table, and keeping `NOTICE` in step.
