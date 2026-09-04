# Shotput

A menu-bar screenshot manager for macOS 26. It watches your screenshot
folder and keeps the last few captures one click from the menu bar, with
optional AI titles and descriptions and semantic search over them.

## Build

```
swift build          # library + executable
./test.sh            # the suite — never bare `swift test`, see the script
./build.sh           # build/Shotput.app, ad-hoc signed
```

There is no Xcode project. `./test.sh` exists because `Testing.framework`
from Command Line Tools resolves itself through `@rpath` and SwiftPM adds no
search path for it, so `swift test` dies at dlopen. Do not move those flags
into `Package.swift`: that builds, runs zero tests, and exits 0.

## Install with chezmoi

Releases are cut from version tags and carry `Shotput.zip`, a
`Shotput.app` bundle. `releases/latest/download` is a stable URL, so this
picks up whatever you last tagged:

```toml
# .chezmoiexternal.toml
["Applications/Shotput.app"]
    type = "archive"
    url = "https://github.com/MichaelCWarren/Shotput/releases/latest/download/Shotput.zip"
    stripComponents = 1
    exact = true
    refreshPeriod = "168h"
```

Then `chezmoi apply`. Fetching over HTTP sets no quarantine flag, so the
ad-hoc signature is not a problem the way it would be for a browser
download.

One consequence of ad-hoc signing worth knowing: the signature changes with
every build, so macOS treats each release as a new app when it reads the
Ollama Cloud key back from the keychain and asks for access again. Click
Always Allow once per update. A Developer ID signature would end it.

To cut a release:

```
git tag v0.2.0 && git push origin v0.2.0
```

## Layout

`Sources/Shotput` is the library and holds everything. `Sources/ShotputApp`
is a thin main so tests can `@testable import` the app code.
`Tests/ShotputTests` is Swift Testing throughout; there is no XCTest.
