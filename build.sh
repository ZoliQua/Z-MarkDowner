#!/bin/bash
# Builds Z-MarkDowner.app into ./build (release).
#   ./build.sh             build the app
#   ./build.sh install     build and copy to /Applications (registers Quick Look + Services)
#   ./build.sh dmg         build and create build/Z-MarkDowner-<version>.dmg
#   ./build.sh test        unit tests + end-to-end self test of the built app
#   ./build.sh notarize    sign with Developer ID and notarize (needs DEVELOPER_ID and NOTARY_PROFILE)
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="Z-MarkDowner"
BUNDLE_ID="io.github.zoliqua.zmarkdowner"
VERSION="$( (sed -n 's/^## \[\([0-9][0-9.]*\)\].*/\1/p' CHANGELOG.md 2>/dev/null || true) | head -1)"
VERSION="${VERSION:-2.0.0}"
BUILD_NUMBER="$(git rev-list --count HEAD 2>/dev/null || echo 1)"
BUILD_DIR="build"
APP="$BUILD_DIR/$APP_NAME.app"
APPEX="$APP/Contents/PlugIns/ZMarkDownerQuickLook.appex"
SIGN_ID="${DEVELOPER_ID:--}"
MODE="${1:-build}"

LANGS="en hu de es it fr pt ru sk cs ro tr"

echo "▸ Building (release) $APP_NAME $VERSION ($BUILD_NUMBER)…"
swift build -c release --product ZMarkDowner
swift build -c release --product ZMarkDownerQuickLook
BIN_DIR="$(swift build -c release --show-bin-path)"

echo "▸ Assembling app bundle…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APPEX/Contents/MacOS"
cp "$BIN_DIR/ZMarkDowner" "$APP/Contents/MacOS/$APP_NAME"
cp "$BIN_DIR/ZMarkDownerQuickLook" "$APPEX/Contents/MacOS/ZMarkDownerQuickLook"
strip -x "$APP/Contents/MacOS/$APP_NAME" "$APPEX/Contents/MacOS/ZMarkDownerQuickLook"

# Icon
if [ ! -f "$BUILD_DIR/AppIcon.icns" ] || [ scripts/make_icon.swift -nt "$BUILD_DIR/AppIcon.icns" ]; then
    echo "▸ Rendering icon…"
    rm -rf "$BUILD_DIR/AppIcon.iconset"
    swift scripts/make_icon.swift "$BUILD_DIR/AppIcon.iconset"
    iconutil -c icns "$BUILD_DIR/AppIcon.iconset" -o "$BUILD_DIR/AppIcon.icns"
    rm -rf "$BUILD_DIR/AppIcon.iconset"
fi
cp "$BUILD_DIR/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

# Web renderers (KaTeX, Mermaid) and translations
cp -R Resources/Web "$APP/Contents/Resources/Web"
for lang in $LANGS; do
    if [ -d "Resources/Localization/$lang.lproj" ]; then
        cp -R "Resources/Localization/$lang.lproj" "$APP/Contents/Resources/"
    fi
done

LOCALIZATIONS=""
for lang in $LANGS; do LOCALIZATIONS="$LOCALIZATIONS<string>$lang</string>"; done

SEND_TYPES="<string>net.daringfireball.markdown</string><string>public.plain-text</string><string>org.openxmlformats.wordprocessingml.document</string><string>com.microsoft.word.doc</string><string>public.rtf</string>"
service() { # message, default title
    echo "<dict><key>NSMenuItem</key><dict><key>default</key><string>$2</string></dict><key>NSMessage</key><string>$1</string><key>NSPortName</key><string>$APP_NAME</string><key>NSRequiredContext</key><dict/><key>NSSendFileTypes</key><array>$SEND_TYPES</array></dict>"
}

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>$APP_NAME</string>
    <key>CFBundleDisplayName</key><string>$APP_NAME</string>
    <key>CFBundleExecutable</key><string>$APP_NAME</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleLocalizations</key><array>$LOCALIZATIONS</array>
    <key>CFBundleAllowMixedLocalizations</key><true/>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSSupportsAutomaticTermination</key><false/>
    <key>NSSupportsSuddenTermination</key><false/>
    <key>NSHumanReadableCopyright</key><string>© 2026 Dr. Dul Zoltán · BSD 3-Clause License</string>
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key><string>Markdown document</string>
            <key>CFBundleTypeRole</key><string>Editor</string>
            <key>LSHandlerRank</key><string>Default</string>
            <key>LSItemContentTypes</key><array><string>net.daringfireball.markdown</string></array>
            <key>NSDocumentClass</key><string>MarkdownDocument</string>
        </dict>
        <dict>
            <key>CFBundleTypeName</key><string>LaTeX document</string>
            <key>CFBundleTypeRole</key><string>Editor</string>
            <key>LSHandlerRank</key><string>Alternate</string>
            <key>LSItemContentTypes</key><array><string>org.tug</string><string>org.tug.tex</string><string>org.tug.ltx</string></array>
            <key>NSDocumentClass</key><string>MarkdownDocument</string>
        </dict>
        <dict>
            <key>CFBundleTypeName</key><string>Plain text document</string>
            <key>CFBundleTypeRole</key><string>Editor</string>
            <key>LSHandlerRank</key><string>Alternate</string>
            <key>LSItemContentTypes</key><array><string>public.plain-text</string></array>
            <key>NSDocumentClass</key><string>MarkdownDocument</string>
        </dict>
        <dict>
            <key>CFBundleTypeName</key><string>Importable document</string>
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
                <string>com.adobe.pdf</string>
            </array>
            <key>NSDocumentClass</key><string>MarkdownDocument</string>
        </dict>
    </array>
    <key>UTImportedTypeDeclarations</key>
    <array>
        <dict>
            <key>UTTypeIdentifier</key><string>net.daringfireball.markdown</string>
            <key>UTTypeDescription</key><string>Markdown document</string>
            <key>UTTypeConformsTo</key><array><string>public.plain-text</string></array>
            <key>UTTypeTagSpecification</key>
            <dict>
                <key>public.filename-extension</key>
                <array><string>md</string><string>markdown</string><string>mdown</string><string>mkd</string><string>mkdn</string></array>
                <key>public.mime-type</key><array><string>text/markdown</string></array>
            </dict>
        </dict>
        <dict>
            <key>UTTypeIdentifier</key><string>org.tug</string>
            <key>UTTypeDescription</key><string>LaTeX document</string>
            <key>UTTypeConformsTo</key><array><string>public.plain-text</string></array>
            <key>UTTypeTagSpecification</key>
            <dict>
                <key>public.filename-extension</key><array><string>tex</string><string>latex</string><string>ltx</string></array>
                <key>public.mime-type</key><array><string>application/x-tex</string></array>
            </dict>
        </dict>
    </array>
    <key>NSServices</key>
    <array>
        $(service convertToPDF "Z-MarkDowner: Convert to PDF")
        $(service convertToDOCX "Z-MarkDowner: Convert to Word (DOCX)")
        $(service convertToMarkdown "Z-MarkDowner: Convert to Markdown")
        $(service openInZMarkDowner "Open in Z-MarkDowner")
    </array>
</dict>
</plist>
PLIST
printf 'APPL????' > "$APP/Contents/PkgInfo"

cat > "$APPEX/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>ZMarkDownerQuickLook</string>
    <key>CFBundleDisplayName</key><string>Z-MarkDowner Quick Look</string>
    <key>CFBundleExecutable</key><string>ZMarkDownerQuickLook</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID.quicklook</string>
    <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundlePackageType</key><string>XPC!</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>NSExtension</key>
    <dict>
        <key>NSExtensionPointIdentifier</key><string>com.apple.quicklook.preview</string>
        <key>NSExtensionPrincipalClass</key><string>PreviewProvider</string>
        <key>NSExtensionAttributes</key>
        <dict>
            <key>QLIsDataBasedPreview</key><true/>
            <key>QLSupportsSearchableItems</key><false/>
            <key>QLSupportedContentTypes</key><array><string>net.daringfireball.markdown</string></array>
        </dict>
    </dict>
</dict>
</plist>
PLIST

echo "▸ Signing ($SIGN_ID)…"
TIMESTAMP=""
RUNTIME=""
if [ "$SIGN_ID" != "-" ]; then TIMESTAMP="--timestamp"; RUNTIME="--options runtime"; fi
codesign --force $TIMESTAMP $RUNTIME --entitlements scripts/QuickLook.entitlements --sign "$SIGN_ID" "$APPEX"
codesign --force $TIMESTAMP $RUNTIME --sign "$SIGN_ID" "$APP"
codesign --verify --strict "$APP"

case "$MODE" in
install)
    echo "▸ Installing to /Applications…"
    rm -rf "/Applications/$APP_NAME.app"
    cp -R "$APP" /Applications/
    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "/Applications/$APP_NAME.app"
    pluginkit -a "/Applications/$APP_NAME.app/Contents/PlugIns/ZMarkDownerQuickLook.appex" 2>/dev/null || true
    /System/Library/CoreServices/pbs -update 2>/dev/null || true
    qlmanage -r >/dev/null 2>&1 || true
    ;;
dmg|notarize)
    DMG="$BUILD_DIR/$APP_NAME-$VERSION.dmg"
    echo "▸ Creating $DMG…"
    STAGE="$BUILD_DIR/dmg"
    rm -rf "$STAGE" "$DMG"
    mkdir -p "$STAGE"
    cp -R "$APP" "$STAGE/"
    ln -s /Applications "$STAGE/Applications"
    hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
    rm -rf "$STAGE"
    if [ "$MODE" = "notarize" ]; then
        : "${NOTARY_PROFILE:?Set NOTARY_PROFILE (xcrun notarytool store-credentials)}"
        [ "$SIGN_ID" != "-" ] || { echo "Set DEVELOPER_ID to a 'Developer ID Application' identity"; exit 1; }
        codesign --force --timestamp --sign "$SIGN_ID" "$DMG"
        xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
        xcrun stapler staple "$DMG"
    fi
    echo "✓ $DMG"
    ;;
test)
    echo "▸ Unit tests…"
    swift test
    echo "▸ End-to-end self test…"
    OUT="$BUILD_DIR/selftest"
    rm -rf "$OUT"
    ZMD_SELFTEST_IN="${ZMD_SELFTEST_IN:-Tests/Fixtures}" ZMD_SELFTEST_OUT="$OUT" \
        "$APP/Contents/MacOS/$APP_NAME" -ApplePersistenceIgnoreState YES >/dev/null 2>&1
    cat "$OUT/selftest-report.txt"
    grep -q "FAIL" "$OUT/selftest-report.txt" && exit 1
    ;;
esac

echo "✓ Done: $APP"
