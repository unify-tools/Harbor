#!/bin/zsh
# 编译并组装 build/Harbor.app。
# 用法：scripts/bundle.sh [debug|release]，默认 release
# 签名：钥匙串里有「Harbor Self-Signed」证书就用它（身份固定，授予过的权限在更新后保留），
# 没有就退回临时签名；也可以用 HARBOR_SIGN_IDENTITY 指定
set -euo pipefail
cd "$(dirname "$0")/.."
CONFIG=${1:-release}

swift build -c "$CONFIG" --product Harbor
BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"

APP=build/Harbor.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Frameworks" "$APP/Contents/Resources/zh-Hans.lproj"
cp "$BIN_DIR/Harbor" "$APP/Contents/MacOS/Harbor"
cp Resources/Info.plist "$APP/Contents/Info.plist"
# 构建号用提交数，保证递增（Sparkle 按它比较新旧）
plutil -replace CFBundleVersion -string "$(git rev-list --count HEAD)" "$APP/Contents/Info.plist"

# Sparkle：SwiftPM 把框架放在可执行文件旁边，app 里要放进 Frameworks 并加上对应的 rpath
ditto "$BIN_DIR/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"
install_name_tool -add_rpath @executable_path/../Frameworks "$APP/Contents/MacOS/Harbor"

IDENTITY=${HARBOR_SIGN_IDENTITY:-$(security find-identity -p codesigning 2>/dev/null | awk '/"Harbor Self-Signed"/ { print $2; exit }')}
IDENTITY=${IDENTITY:--}
# 由内向外签名（Sparkle 文档的顺序），不用 --deep
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
codesign --force --sign "$IDENTITY" "$SPARKLE/XPCServices/Installer.xpc"
codesign --force --sign "$IDENTITY" --preserve-metadata=entitlements "$SPARKLE/XPCServices/Downloader.xpc"
codesign --force --sign "$IDENTITY" "$SPARKLE/Autoupdate"
codesign --force --sign "$IDENTITY" "$SPARKLE/Updater.app"
codesign --force --sign "$IDENTITY" "$APP/Contents/Frameworks/Sparkle.framework"
codesign --force --sign "$IDENTITY" "$APP"
codesign --verify --strict "$APP"
if [[ $IDENTITY == - ]]; then
  echo "已生成 $APP（临时签名：每次构建签名都会变，授予过的权限需要重新授权）"
else
  echo "已生成 $APP（签名身份 $IDENTITY）"
fi
