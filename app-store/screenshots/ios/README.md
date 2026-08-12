# iOS App Store screenshots

The upload screenshots are composed from real Textream simulator captures. The
headline treatment deliberately follows the existing macOS set: a dark indigo
background, restrained blue/orange orbital light, an uppercase eyebrow, a bold
two-line promise, and the real product UI beneath it.

## Generate the upload set

```sh
swift app-store/screenshots/ios/compose.swift
```

The script writes opaque sRGB PNG files at the App Store Connect dimensions:

- `upload/iphone-6.5/`: three screenshots at 1284 × 2778
- `upload/ipad-13/`: three screenshots at 2064 × 2752
- `contact-sheet.png`: review-only overview of both upload sets

The source captures live under `raw/iphone-6.9/` and `raw/ipad-13/`. They use
the app's DEBUG-only launch routes for stable, private-data-free views; those
routes are not present in the App Store build.
