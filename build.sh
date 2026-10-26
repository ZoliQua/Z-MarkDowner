#!/bin/bash
# Builds Z-MarkDowner.app into ./build (release, ad-hoc signed).
#   ./build.sh            build
#   ./build.sh install    build and copy to /Applications
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="Z-MarkDowner"
BUNDLE_ID="hu.zoli.zmarkdowner"
VERSION="1.0.0"
BUILD_DIR="build"
APP="$BUILD_DIR/$APP_NAME.app"

echo "▸ Fordítás (release)…"
swift build -c release --product ZMarkDowner
BIN="$(swift build -c release --show-bin-path)/ZMarkDowner"

echo "▸ App bundle összeállítása…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$APP_NAME"

ICONSET="$BUILD_DIR/AppIcon.iconset"
if [ ! -f "$BUILD_DIR/AppIcon.icns" ] || [ scripts/make_icon.swift -nt "$BUILD_DIR/AppIcon.icns" ]; then
    echo "▸ Ikon generálása…"
    rm -rf "$ICONSET"
    swift scripts/make_icon.swift "$ICONSET"
    iconutil -c icns "$ICONSET" -o "$BUILD_DIR/AppIcon.icns"
    rm -rf "$ICONSET"
fi
cp "$BUILD_DIR/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>$APP_NAME</string>
    <key>CFBundleDisplayName</key><string>$APP_NAME</string>
    <key>CFBundleExecutable</key><string>$APP_NAME</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleDevelopmentRegion</key><string>hu</string>
    <key>CFBundleLocalizations</key><array><string>hu</string></array>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSSupportsAutomaticTermination</key><false/>
    <key>NSSupportsSuddenTermination</key><false/>
    <key>NSHumanReadableCopyright</key><string>© 2026 Zoli</string>
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key><string>Markdown dokumentum</string>
            <key>CFBundleTypeRole</key><string>Editor</string>
            <key>LSHandlerRank</key><string>Default</string>
            <key>LSItemContentTypes</key><array><string>net.daringfireball.markdown</string></array>
            <key>NSDocumentClass</key><string>MarkdownDocument</string>
        </dict>
        <dict>
            <key>CFBundleTypeName</key><string>Szöveges dokumentum</string>
            <key>CFBundleTypeRole</key><string>Editor</string>
            <key>LSHandlerRank</key><string>Alternate</string>
            <key>LSItemContentTypes</key><array><string>public.plain-text</string></array>
            <key>NSDocumentClass</key><string>MarkdownDocument</string>
        </dict>
        <dict>
            <key>CFBundleTypeName</key><string>Importálható dokumentum</string>
            <key>CFBundleTypeRole</key><string>Viewer</string>
            <key>LSHandlerRank</key><string>Alternate</string>
            <key>LSItemContentTypes</key>
            <array>
                <string>org.openxmlformats.wordprocessingml.document</string>
                <string>com.microsoft.word.doc</string>
                <string>public.rtf</string>
                <string>com.apple.rtfd</string>
                <string>org.oasis-open.opendocument.text</string>
                <string>public.html</string>
            </array>
            <key>NSDocumentClass</key><string>MarkdownDocument</string>
        </dict>
    </array>
    <key>UTImportedTypeDeclarations</key>
    <array>
        <dict>
            <key>UTTypeIdentifier</key><string>net.daringfireball.markdown</string>
            <key>UTTypeDescription</key><string>Markdown dokumentum</string>
            <key>UTTypeConformsTo</key><array><string>public.plain-text</string></array>
            <key>UTTypeTagSpecification</key>
            <dict>
                <key>public.filename-extension</key>
                <array><string>md</string><string>markdown</string><string>mdown</string><string>mkd</string><string>mkdn</string></array>
                <key>public.mime-type</key><array><string>text/markdown</string></array>
            </dict>
        </dict>
    </array>
</dict>
</plist>
PLIST
printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "▸ Aláírás (ad-hoc)…"
codesign --force --deep --sign - "$APP"

if [ "${1:-}" = "install" ]; then
    echo "▸ Telepítés: /Applications/$APP_NAME.app"
    rm -rf "/Applications/$APP_NAME.app"
    cp -R "$APP" /Applications/
    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "/Applications/$APP_NAME.app"
fi

echo "✓ Kész: $APP"
