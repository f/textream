# Prompter layout regression tests

Run the native layout checks on macOS with Xcode selected:

```sh
./scripts/test-prompter-layout.sh
```

If Command Line Tools are selected instead, set `DEVELOPER_DIR` to your Xcode installation. The runner compiles the production layout and its alignment/direction helpers into a temporary executable. It adds only the two-case reading-position enum needed to compile the view without application services. Tests are appended to the layout's source file so its private cache can be checked without exposing it in the app.

The checks compare packed rows with actual SwiftUI text widths, preserve word offsets and paragraph metadata, and exercise middle-only script edits. They cover Chinese mixed with numbers, dates, English, cues, and RTL samples at several fonts and widths. OpenDyslexic is included when the bundled font registers successfully. Single tokens wider than the container are checked for their own row; this change does not introduce a new long-token wrapping policy.

Run the browser renderer checks with Node.js:

```sh
node tests/browser-layout.test.cjs
```

This executes the embedded production script in an isolated context with a small DOM and WebSocket stub. It tests span updates and offsets without a network connection. It does not verify browser geometry or a live remote device.
