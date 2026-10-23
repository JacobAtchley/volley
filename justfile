set shell := ["bash", "-euo", "pipefail", "-c"]

android_id := "app.volley.android"
mac_app := "mac/build/Build/Products/Debug/Volley.app"

# List recipes
default:
    @just --list

# Build both apps, install on the phone, and open the Mac app
all: build deploy open

# Build the Android and macOS apps
build: build-android build-mac

# Build the Android debug APK
build-android:
    cd android && ./gradlew assembleDebug

# Generate the Xcode project and build the macOS app
build-mac:
    @command -v xcodegen >/dev/null || { echo "xcodegen not found: brew install xcodegen"; exit 1; }
    cd mac && xcodegen
    xcodebuild -project mac/Volley.xcodeproj -scheme Volley -configuration Debug \
        -derivedDataPath mac/build build

# Run Android and macOS unit tests
test: test-android test-mac

# Run Android unit tests
test-android:
    cd android && ./gradlew testDebugUnitTest

# Run macOS unit tests
test-mac:
    cd mac && xcodegen
    xcodebuild -project mac/Volley.xcodeproj -scheme Volley -configuration Debug \
        -derivedDataPath mac/build test

# Check style and lint both apps (no changes)
lint: lint-android lint-mac

# ktlint + Android Lint (warnings fail)
lint-android:
    cd android && ./gradlew ktlintCheck lintDebug

# SwiftLint, strict (warnings fail)
lint-mac:
    @command -v swiftlint >/dev/null || { echo "swiftlint not found: brew install swiftlint"; exit 1; }
    cd mac && swiftlint lint --strict

# Auto-fix what the style checkers can fix
format:
    cd android && ./gradlew ktlintFormat
    @command -v swiftlint >/dev/null || { echo "swiftlint not found: brew install swiftlint"; exit 1; }
    cd mac && swiftlint --fix

# Everything the CI gate runs: lint, tests, builds
ci: lint test build

# Install the Android app on the connected device and launch it
deploy:
    cd android && ./gradlew installDebug
    adb shell monkey -p {{android_id}} -c android.intent.category.LAUNCHER 1 >/dev/null

# Open the macOS app (quits a running copy first)
open:
    -pkill -x Volley
    @while pgrep -x Volley >/dev/null; do sleep 0.2; done
    open "{{mac_app}}"

# Remove build outputs
clean:
    cd android && ./gradlew clean
    rm -rf mac/build
