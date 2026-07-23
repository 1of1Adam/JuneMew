#!/bin/bash
#
# JuneMew 发版脚本。
#
# 用法:
#   scripts/release.sh "本次更新说明(会显示在 Sparkle 更新弹窗里)"
#
# 前置:
#   - pbxproj 里的 MARKETING_VERSION / CURRENT_PROJECT_VERSION 已升好
#   - Sparkle ed25519 私钥在 login Keychain(generate_keys 生成;
#     备份在 ~/Documents/JuneMew-sparkle-private-key.pem,丢失即永远无法发版)
#   - gh 已登录
#
# 产出:
#   - GitHub Release v<版本> 附 JuneMew-<版本>.zip(Sparkle 更新包)与 DMG(首装)
#   - appcast.xml 更新并推送 —— 已装用户 24h 内收到更新提示

set -euo pipefail
cd "$(dirname "$0")/.."

NOTES="${1:?用法: scripts/release.sh \"更新说明\"}"

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode-beta.app/Contents/Developer}"

VERSION=$(sed -n 's/.*MARKETING_VERSION = \(.*\);/\1/p' MewNotch.xcodeproj/project.pbxproj | head -1)
BUILD=$(sed -n 's/.*CURRENT_PROJECT_VERSION = \(.*\);/\1/p' MewNotch.xcodeproj/project.pbxproj | head -1)
echo "==> 发布 JuneMew ${VERSION} (build ${BUILD})"

# ── 1. 构建 ──────────────────────────────────────────────────────────
# 密钥注入：把本机 DeepSeek key 混淆后写进 bundle 资源（gitignore，
# 永不进 git）。key 文件不存在时跳过，翻译功能不启用。
scripts/gen-secrets.sh

# 先杀掉从 build 目录启动的实例：运行中的进程占用二进制会让构建收尾
# （签名/链接）静默失败。只匹配 build 路径，不动 /Applications 里的正式版。
pkill -f "build/Build/Products/Release/JuneMew.app" 2>/dev/null || true

xcodebuild -project MewNotch.xcodeproj -scheme MewNotch \
    -configuration Release -derivedDataPath build build -quiet
APP="build/Build/Products/Release/JuneMew.app"
[ -d "$APP" ] || { echo "构建产物不存在: $APP"; exit 1; }

PLIST_VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")
[ "$PLIST_VERSION" = "$VERSION" ] || { echo "版本不一致: pbxproj=$VERSION app=$PLIST_VERSION"; exit 1; }

# ── 2. 打包: zip 给 Sparkle,DMG 给首次安装 ─────────────────────────
mkdir -p dist
ZIP="dist/JuneMew-${VERSION}.zip"
rm -f "$ZIP"

ditto -c -k --keepParent "$APP" "$ZIP"

rm -rf dist/stage/JuneMew.app
mkdir -p dist/stage
[ -L dist/stage/Applications ] || ln -s /Applications dist/stage/Applications
ditto "$APP" dist/stage/JuneMew.app
# macOS 26 起 hdiutil create 已不可用（报 No such file or directory），
# 必须用 diskutil 的新命令。发现于 1.3 发版：脚本静默死在这一步。
#
# DMG 产出到临时目录而不是 dist/：dist/ 下的 DMG 路径被 1.3 发版时
# hdiutil 失败遗留的僵尸清理盯上 —— 文件落地数秒内被异步删除，而
# diskutil 退出码仍是 0，v1.4 发版就这样静默丢了 DMG 直到 gh 上传才
# 报错。临时目录不背这个诅咒；文件名保持正确，gh 的 asset 名跟文件走。
DMG_DIR=$(mktemp -d)
DMG="$DMG_DIR/JuneMew-${VERSION}.dmg"
diskutil image create from dist/stage "$DMG" --format UDZO --volumeName "JuneMew ${VERSION}" > /dev/null
# diskutil 成功退出不等于文件还在（见上）—— 上传前必须亲眼确认。
sleep 3
[ -f "$DMG" ] || { echo "DMG 未产出或已被异步清理: $DMG"; exit 1; }

# ── 3. ed25519 签名 ──────────────────────────────────────────────────
# 用导出的私钥文件而不是 Keychain：钥匙串每次读取都会弹授权框等人工
# 输入，发版脚本必须能无人值守跑完。文件不存在时回落 Keychain。
SPARKLE_BIN="build/SourcePackages/artifacts/sparkle/Sparkle/bin"
KEY_FILE="$HOME/Documents/JuneMew-sparkle-private-key.pem"
if [ -f "$KEY_FILE" ]; then
    SIG_OUTPUT=$("$SPARKLE_BIN/sign_update" -f "$KEY_FILE" "$ZIP")
else
    SIG_OUTPUT=$("$SPARKLE_BIN/sign_update" "$ZIP")
fi
ED_SIGNATURE=$(echo "$SIG_OUTPUT" | sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p')
LENGTH=$(echo "$SIG_OUTPUT" | sed -n 's/.*length="\([^"]*\)".*/\1/p')
[ -n "$ED_SIGNATURE" ] || { echo "签名失败: $SIG_OUTPUT"; exit 1; }
echo "==> 签名 OK (${LENGTH} bytes)"

# ── 4. appcast.xml(只保留最新版 —— Sparkle 永远选最高版本)────────
DOWNLOAD_URL="https://github.com/1of1Adam/JuneMew/releases/download/v${VERSION}/JuneMew-${VERSION}.zip"
PUB_DATE=$(LC_ALL=en_US.UTF-8 date -u "+%a, %d %b %Y %H:%M:%S +0000")

cat > appcast.xml <<APPCAST
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>JuneMew</title>
    <link>https://github.com/1of1Adam/JuneMew</link>
    <item>
      <title>JuneMew ${VERSION}</title>
      <pubDate>${PUB_DATE}</pubDate>
      <sparkle:version>${BUILD}</sparkle:version>
      <sparkle:shortVersionString>${VERSION}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>15.2</sparkle:minimumSystemVersion>
      <description><![CDATA[
        ${NOTES}
      ]]></description>
      <enclosure
        url="${DOWNLOAD_URL}"
        sparkle:edSignature="${ED_SIGNATURE}"
        length="${LENGTH}"
        type="application/octet-stream"/>
    </item>
  </channel>
</rss>
APPCAST

# ── 5. GitHub Release + 推送 appcast ─────────────────────────────────
gh release create "v${VERSION}" "$ZIP" "$DMG" \
    --title "JuneMew ${VERSION}" \
    --notes "$NOTES"

git add appcast.xml
git commit -m "release: v${VERSION} appcast"
git push

echo "==> 完成。已装用户将在 24h 内收到 ${VERSION} 更新提示。"
