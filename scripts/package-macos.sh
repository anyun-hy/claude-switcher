#!/bin/bash
# Claude 切换器 - macOS 打包脚本（本地与 CI 共用）
# 用法: bash scripts/package-macos.sh [版本号]
# 产物: build/ClaudeSwitcher-<版本>-macos-<架构>.zip
#       build/ClaudeSwitcher-<版本>-macos-<架构>.dmg
#       build/ClaudeSwitcher-<版本>-installer-kit.zip
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

VERSION="${1:-0.0.0-dev}"
case "$VERSION" in
    ''|*[!0-9A-Za-z._-]*)
        echo "✗ 版本号只能包含字母、数字、点、下划线和连字符: $VERSION" >&2
        exit 1
        ;;
esac

APP_NAME="Claude切换器"
BUILD="$ROOT/build"
APP="$BUILD/$APP_NAME.app"
ARCH="$(uname -m)"
case "$ARCH" in
    arm64)  ARCH_LABEL="arm64" ;;
    x86_64) ARCH_LABEL="x86_64" ;;
    *)      ARCH_LABEL="$ARCH" ;;
esac
ZIP="$BUILD/ClaudeSwitcher-$VERSION-macos-$ARCH_LABEL-app-only.zip"
DMG="$BUILD/ClaudeSwitcher-$VERSION-macos-$ARCH_LABEL-app-only.dmg"
KIT_NAME="ClaudeSwitcher-$VERSION"
KIT_ZIP="$BUILD/ClaudeSwitcher-$VERSION-installer-kit.zip"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/claude-switcher-package.XXXXXX")"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

mkdir -p "$BUILD"
rm -rf "$APP" "$ZIP" "$DMG" "$KIT_ZIP"

echo "==> 编译并签名 $APP_NAME $VERSION ($ARCH_LABEL)"
CLAUDE_SWITCHER_SWIFTC_FLAGS="-warnings-as-errors" bash "$ROOT/scripts/build-app.sh" "$ROOT" "$APP" "$VERSION"
plutil -lint "$APP/Contents/Info.plist" >/dev/null
echo "✓ App 构建与 ad-hoc 签名完成"

NOTE="$WORK/安装说明.txt"
cat > "$NOTE" <<'NOTE_EOF'
这是仅包含 macOS 界面 App 的安装包，不含核心脚本与守护进程。

首次使用请下载 installer-kit.zip，解压后双击 installer/安装.command。
若已安装过核心脚本，可把本 App 拖入「应用程序」覆盖旧版界面。

未安装核心脚本时，App 会提示「还差一步：安装核心脚本」并提供下载入口。
NOTE_EOF

echo "==> 生成 macOS zip(app-only)"
APP_STAGE="$WORK/appstage"
mkdir -p "$APP_STAGE"
ditto "$APP" "$APP_STAGE/$APP_NAME.app"
cp "$NOTE" "$APP_STAGE/安装说明.txt"
ditto -c -k --norsrc --noextattr "$APP_STAGE" "$ZIP"

echo "==> 生成 DMG(app-only)"
DMG_STAGE="$WORK/dmg"
mkdir -p "$DMG_STAGE"
ditto "$APP" "$DMG_STAGE/$APP_NAME.app"
cp "$NOTE" "$DMG_STAGE/安装说明.txt"
ln -s /Applications "$DMG_STAGE/Applications"
hdiutil create -quiet -volname "$APP_NAME" -srcfolder "$DMG_STAGE" \
    -ov -format UDZO "$DMG" >/dev/null

echo "==> 生成 installer kit"
KIT_ROOT="$WORK/$KIT_NAME"
mkdir -p "$KIT_ROOT"
for FILE in README.md README.en.md AGENTS.md SECURITY.md LICENSE; do
    cp "$ROOT/$FILE" "$KIT_ROOT/"
done
for DIR in core daemons installer app; do
    ditto "$ROOT/$DIR" "$KIT_ROOT/$DIR"
done
mkdir -p "$KIT_ROOT/assets" "$KIT_ROOT/docs" "$KIT_ROOT/scripts"
cp "$ROOT/assets/icon-2048.png" "$KIT_ROOT/assets/"
cp "$ROOT/docs/screenshot.png" "$KIT_ROOT/docs/"
cp "$ROOT/scripts/build-app.sh" "$KIT_ROOT/scripts/"
chmod +x "$KIT_ROOT/installer/安装.command" "$KIT_ROOT/installer/卸载.command" "$KIT_ROOT/scripts/build-app.sh"
for ITEM in \
    README.md README.en.md AGENTS.md SECURITY.md LICENSE \
    core/claude-switch.sh daemons/claude-bodyguard.sh installer/安装.command \
    scripts/build-app.sh app/main.swift assets/icon-2048.png docs/screenshot.png; do
    if [ ! -e "$KIT_ROOT/$ITEM" ]; then
        echo "✗ installer kit 缺少 $ITEM" >&2
        exit 1
    fi
done
ditto -c -k --keepParent --norsrc --noextattr "$KIT_ROOT" "$KIT_ZIP"

echo ""
echo "✓ 打包完成:"
for FILE in "$ZIP" "$DMG" "$KIT_ZIP"; do
    [ -f "$FILE" ] || { echo "✗ 缺少产物 $FILE" >&2; exit 1; }
    printf '  %-58s %8s\n' "$(basename "$FILE")" "$(du -h "$FILE" | cut -f1)"
done
