# SwiftTerm, vendored

- Source: https://github.com/migueldeicaza/SwiftTerm, tag `v1.99.1`, commit `2f573f73af5e768d90847dce20c97fa9535d7164`.
- License: MIT (see `LICENSE`).
- Copied: `Sources/SwiftTerm` only, without `Documentation.docc`, `Mac/README.md` and
  `Apple/Metal/Shaders.metal` (the Metal renderer compiles its shaders from source at runtime).
- Added: `Sources/SwiftTerm/Generated/`, two files upstream generates with a build plugin.
  Written by hand so the build needs no plugin and no network. The XTGETTCAP table keeps
  only the true-color and color-count replies.
- Changed: `Pty.swift`'s `fork` closes descriptors 3 and up in the child before `execve`,
  so shells don't inherit the app's sockets and files (marked "Dynamic Notch").
- Nothing else is changed. To update, copy a newer `Sources/SwiftTerm` the same way and
  re-check the two generated files against upstream's generator.
