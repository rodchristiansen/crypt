#!/bin/bash
# Builds an unsigned, unnotarised Crypt-<version>.pkg that installs everything
# the signed `make dist` package installs: the authorisation plugin, the
# checkin binary, its LaunchDaemon, the log rotation rule and the install
# scripts. A release publishes this package; whoever deploys it signs every
# binary inside, innermost first, and then the package itself.
#
# Usage: Package/build-unsigned-pkg.sh <version> <build-number> [output-dir]
#   version       the package version, e.g. 2026.10.06.1800
#   build-number  Crypt.bundle's CFBundleVersion, digits only and above any
#                 build already installed, e.g. 202610061800
set -euo pipefail

VERSION="${1:?usage: build-unsigned-pkg.sh <version> <build-number> [output-dir]}"
BUILD_NUMBER="${2:?usage: build-unsigned-pkg.sh <version> <build-number> [output-dir]}"
OUT_DIR="${3:-build/pkg}"

if ! [[ "$BUILD_NUMBER" =~ ^[0-9]+$ ]]; then
    echo "build number must be digits only: $BUILD_NUMBER" >&2
    exit 1
fi

cd "$(dirname "$0")/.."
REPO_ROOT="$(pwd)"
WORK="$REPO_ROOT/build/unsigned-pkg"
ROOT="$WORK/root"
SCRIPTS="$WORK/scripts"
IDENTIFIER="com.grahamgilbert.Crypt"
PLUGIN_NAME="Crypt.bundle"

rm -rf "$WORK"
mkdir -p "$ROOT" "$SCRIPTS" "$OUT_DIR"

echo "Building the authorisation plugin"
# The project's build phase stamps CFBundleVersion into the source Info.plist,
# which the copy step has already read, so the stamp only lands on the next
# build. Leave the script sandbox off so that phase can still run, and stamp
# the built bundle directly below.
xcodebuild -project Crypt.xcodeproj -configuration Release -scheme Crypt \
    -derivedDataPath "$WORK/xcode" -arch arm64 -arch x86_64 ONLY_ACTIVE_ARCH=NO \
    CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= \
    ENABLE_USER_SCRIPT_SANDBOXING=NO CRYPT_BUILD_NUMBER="$BUILD_NUMBER" \
    build >"$WORK/xcodebuild.log" 2>&1 || { tail -40 "$WORK/xcodebuild.log" >&2; exit 1; }
git checkout -- Crypt/Info.plist 2>/dev/null || true

PLUGIN_SRC="$WORK/xcode/Build/Products/Release/$PLUGIN_NAME"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$PLUGIN_SRC/Contents/Info.plist"
codesign --force --sign - "$PLUGIN_SRC"

echo "Building checkin"
SHORT_VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Crypt/Info.plist)
/usr/bin/sed -i '' "s/^let cryptVersion = .*/let cryptVersion = \"${SHORT_VERSION}\"/" Sources/checkin/Version.swift
MACOSX_DEPLOYMENT_TARGET=13.0 swift build -c release --arch arm64 --arch x86_64 --product checkin
# The universal output folder differs between toolchains, so ask for it.
CHECKIN_BIN="$(MACOSX_DEPLOYMENT_TARGET=13.0 swift build -c release --arch arm64 --arch x86_64 --product checkin --show-bin-path)/checkin"
archs="$(lipo -archs "$CHECKIN_BIN")"
[[ "$archs" == *arm64* && "$archs" == *x86_64* ]] || { echo "checkin is not universal: $archs" >&2; exit 1; }
git checkout -- Sources/checkin/Version.swift 2>/dev/null || true

echo "Staging the payload"
install -d -m 755 "$ROOT/Library/Security/SecurityAgentPlugins" "$ROOT/Library/Crypt" \
    "$ROOT/Library/LaunchDaemons" "$ROOT/private/etc/newsyslog.d"
ditto "$PLUGIN_SRC" "$ROOT/Library/Security/SecurityAgentPlugins/$PLUGIN_NAME"
install -m 755 "$CHECKIN_BIN" "$ROOT/Library/Crypt/checkin"
install -m 644 Package/com.grahamgilbert.crypt.plist "$ROOT/Library/LaunchDaemons/com.grahamgilbert.crypt.plist"
install -m 644 Package/newsyslog.d/crypt.conf "$ROOT/private/etc/newsyslog.d/crypt.conf"
install -m 755 Package/preinstall Package/postinstall "$SCRIPTS/"
/usr/bin/xattr -cr "$ROOT"

# Never let the installer skip the plugin because the bundle on the Mac has a
# higher CFBundleVersion, and never relocate it to wherever a copy was moved.
pkgbuild --analyze --root "$ROOT" "$WORK/component.plist" >/dev/null
i=0
while plutil -extract "$i" xml1 -o /dev/null "$WORK/component.plist" 2>/dev/null; do
    plutil -replace "$i.BundleIsVersionChecked" -bool NO "$WORK/component.plist"
    plutil -replace "$i.BundleIsRelocatable" -bool NO "$WORK/component.plist"
    i=$((i + 1))
done

COPYFILE_DISABLE=1 pkgbuild --root "$ROOT" --component-plist "$WORK/component.plist" --scripts "$SCRIPTS" \
    --identifier "$IDENTIFIER" --version "$VERSION" --ownership recommended \
    --info Package/PackageInfo "$WORK/Crypt.pkg"

sed "s/replace_version/${VERSION}/g" Package/Distribution-Template > "$WORK/Distribution"
productbuild --distribution "$WORK/Distribution" --package-path "$WORK" "$OUT_DIR/Crypt-${VERSION}.pkg"

# Fail the release if the stamp did not land where the installer reads it.
expanded="$WORK/check"
pkgutil --expand "$OUT_DIR/Crypt-${VERSION}.pkg" "$expanded"
grep -q "CFBundleVersion=\"$BUILD_NUMBER\"" "$expanded/Crypt.pkg/PackageInfo" || {
    echo "Crypt.bundle does not carry build number $BUILD_NUMBER" >&2
    exit 1
}
echo "Built $OUT_DIR/Crypt-${VERSION}.pkg (Crypt.bundle $BUILD_NUMBER)"
