#!/usr/bin/env bash
# Build the CorridorKey FxPlug wrapper app and install it to ~/Applications.
#   ./build.sh                      # ad-hoc signed ("Sign to Run Locally")
#   DEVELOPMENT_TEAM=ABCDE12345 ./build.sh
set -euo pipefail
cd "$(dirname "$0")"

if [ ! -d /Library/Developer/Frameworks/FxPlug.framework ]; then
    echo "error: FxPlug SDK not installed. Download it from" >&2
    echo "       https://developer.apple.com/download/all/?q=FxPlug" >&2
    exit 1
fi
if ! command -v xcodegen >/dev/null; then
    echo "error: xcodegen not found (brew install xcodegen)" >&2
    exit 1
fi

xcodegen generate
team_args=()
if [ -n "${DEVELOPMENT_TEAM:-}" ]; then
    team_args=(DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM" CODE_SIGN_IDENTITY="Apple Development")
fi
xcodebuild -project CorridorKeyFxPlug.xcodeproj -scheme CorridorKey \
    -configuration Release -derivedDataPath build \
    ${team_args[@]+"${team_args[@]}"} build

app="build/Build/Products/Release/CorridorKey.app"
mkdir -p "$HOME/Applications"
rm -rf "$HOME/Applications/CorridorKey.app"
ditto "$app" "$HOME/Applications/CorridorKey.app"
echo "Installed $HOME/Applications/CorridorKey.app"

# Launching the wrapper app once registers the plug-in with PlugInKit.
open "$HOME/Applications/CorridorKey.app"
sleep 2
pluginkit -m -p FxPlug | grep -i corridor || \
    echo "warning: PlugInKit doesn't list CorridorKey yet; see README troubleshooting"
