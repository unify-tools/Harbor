#!/bin/zsh
# 编译并组装 build/Harbor.app（本地临时签名）。
# 用法：scripts/bundle.sh [debug|release]，默认 release
set -euo pipefail
cd "$(dirname "$0")/.."
CONFIG=${1:-release}

swift build -c "$CONFIG" --product Harbor
BIN="$(swift build -c "$CONFIG" --show-bin-path)/Harbor"

APP=build/Harbor.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/zh-Hans.lproj"
cp "$BIN" "$APP/Contents/MacOS/Harbor"
cp Resources/Info.plist "$APP/Contents/Info.plist"
# 临时签名：每次构建签名都会变，授予过的「完全磁盘访问权限」需要重新授权
codesign --force --sign - "$APP"
echo "已生成 $APP"
