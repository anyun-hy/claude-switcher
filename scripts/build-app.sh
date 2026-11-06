#!/bin/bash
# 统一编译并签名 macOS 界面 App（安装器 / 打包脚本 / 应用内更新共用）
# 用法: bash scripts/build-app.sh <repo_root> <output_app_path> [version] [fallback_icns]
set -euo pipefail

REPO_ROOT="${1:?用法: build-app.sh <repo_root> <output_app_path> [version] [fallback_icns]}"
APP_OUT="${2:?用法: build-app.sh <repo_root> <output_app_path> [version] [fallback_icns]}"
VERSION="${3:-1.0}"
FALLBACK_ICNS="${4:-}"
BUILD_VERSION="$VERSION"
[ "$VERSION" = "1.0" ] && BUILD_VERSION="1"

if ! command -v swiftc >/dev/null 2>&1; then
    echo "FAIL:未检测到 swiftc,无法编译界面 App" >&2
    exit 1
fi

ARCH="$(uname -m)"
mkdir -p "$APP_OUT/Contents/MacOS" "$APP_OUT/Contents/Resources"

# 必须带 -target,否则新 SDK 编出的二进制在老系统被拒启动
# shellcheck disable=SC2086
if ! swiftc -O -parse-as-library ${CLAUDE_SWITCHER_SWIFTC_FLAGS:-} \
    -target "$ARCH-apple-macos13.0" \
    "$REPO_ROOT/app/main.swift" \
    -o "$APP_OUT/Contents/MacOS/ClaudeSwitcher" \
    -framework SwiftUI -framework AppKit; then
    exit 1
fi

PNG="$REPO_ROOT/assets/icon-2048.png"
if [ -f "$PNG" ]; then
    ICON_WORK="$(mktemp -d "${TMPDIR:-/tmp}/claude-switcher-icon.XXXXXX")"
    ICONSET="$ICON_WORK/AppIcon.iconset"
    mkdir -p "$ICONSET"
    for sz in 16 32 128 256 512; do
        sips -z "$sz" "$sz" "$PNG" --out "$ICONSET/icon_${sz}x${sz}.png" >/dev/null 2>&1 || true
        sips -z $((sz * 2)) $((sz * 2)) "$PNG" --out "$ICONSET/icon_${sz}x${sz}@2x.png" >/dev/null 2>&1 || true
    done
    iconutil -c icns "$ICONSET" -o "$APP_OUT/Contents/Resources/AppIcon.icns" 2>/dev/null || true
    rm -rf "$ICON_WORK"
elif [ -n "$FALLBACK_ICNS" ] && [ -f "$FALLBACK_ICNS" ]; then
    cp "$FALLBACK_ICNS" "$APP_OUT/Contents/Resources/AppIcon.icns" 2>/dev/null || true
fi

APP_SHA="$(shasum -a 256 "$REPO_ROOT/app/main.swift" | awk '{print $1}')"
cat > "$APP_OUT/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleExecutable</key><string>ClaudeSwitcher</string>
	<key>CFBundleIdentifier</key><string>local.claude-switcher</string>
	<key>CFBundleName</key><string>Claude Switcher</string>
	<key>CFBundleDisplayName</key><string>Claude Switcher</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>CFBundleShortVersionString</key><string>$VERSION</string>
	<key>CFBundleVersion</key><string>$BUILD_VERSION</string>
	<key>LSMinimumSystemVersion</key><string>13.0</string>
	<key>CFBundleIconFile</key><string>AppIcon</string>
	<key>ClaudeSwitcherSourceSHA256</key><string>$APP_SHA</string>
	<key>NSHighResolutionCapable</key><true/>
	<key>NSAppleEventsUsageDescription</key><string>用于在您选择的项目文件夹中打开终端并启动 Claude Code。</string>
	<key>LSUIElement</key><true/>
</dict>
</plist>
EOF

if ! codesign --force --deep -s - "$APP_OUT" >/dev/null 2>&1 || ! codesign --verify --deep --strict "$APP_OUT" >/dev/null 2>&1; then
    echo "FAIL:App 签名或校验失败" >&2
    exit 1
fi

