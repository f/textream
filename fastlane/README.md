fastlane documentation
----

# Installation

Make sure you have the latest version of the Xcode command line tools installed:

```sh
xcode-select --install
```

For _fastlane_ installation instructions, see [Installing _fastlane_](https://docs.fastlane.tools/#installing-fastlane)

# Available Actions

## iOS

### ios release

```sh
[bundle exec] fastlane ios release
```

Archive, upload, and submit the iOS app for App Review

The update is released automatically once App Review approves it

### ios archive_build

```sh
[bundle exec] fastlane ios archive_build
```

Archive the iOS app and export an App Store IPA

### ios upload_build

```sh
[bundle exec] fastlane ios upload_build
```

Upload an exported IPA to App Store Connect without submitting it

### ios submit_build

```sh
[bundle exec] fastlane ios submit_build
```

Create the App Store version, set What's New, and submit the uploaded build

----

This README.md is auto-generated and will be re-generated every time [_fastlane_](https://fastlane.tools) is run.

More information about _fastlane_ can be found on [fastlane.tools](https://fastlane.tools).

The documentation of _fastlane_ can be found on [docs.fastlane.tools](https://docs.fastlane.tools).
