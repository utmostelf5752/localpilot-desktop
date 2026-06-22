# LocalPilotDesktop

## Run the app

```sh
xcodebuild build -project LocalPilotDesktop.xcodeproj -scheme LocalPilotDesktop -destination 'platform=macOS' -derivedDataPath build
open build/Build/Products/Debug/LocalPilotDesktop.app
```

If you added or moved Swift files first regenerate the project: `xcodegen` (config in `project.yml`).

## Test

```sh
xcodebuild test -project LocalPilotDesktop.xcodeproj -scheme LocalPilotDesktop -destination 'platform=macOS'
```
