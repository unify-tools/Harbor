#!/bin/zsh
# 发布新版本到 GitHub Releases（Sparkle 从 releases/latest/download/appcast.xml 取更新）。
# 版本号取 Resources/Info.plist 的 CFBundleShortVersionString，先改好、提交并推送再跑。
# 用法：scripts/release.sh           打包、签名、生成 appcast 并上传
#       scripts/release.sh --local   只生成 build/release/ 里的文件，不检查 git、不上传
# 上传用 gh 的 Lakes2 账号（HARBOR_GH_USER 可改），网络不通时先设好 https_proxy
set -euo pipefail
cd "$(dirname "$0")/.."
REPO=unify-tools/Harbor
GH_USER=${HARBOR_GH_USER:-Lakes2}
SPARKLE_BIN=.build/artifacts/sparkle/Sparkle/bin
LOCAL=0
[[ ${1:-} == --local ]] && LOCAL=1

VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Resources/Info.plist)
TAG="v$VERSION"
if (( ! LOCAL )); then
  [[ -z $(git status --porcelain) ]] || { echo "有未提交的改动，先提交" >&2; exit 1; }
  git fetch -q origin
  [[ $(git rev-parse HEAD) == $(git rev-parse @{u}) ]] || { echo "HEAD 和远程不一致，先推送" >&2; exit 1; }
  if GH_TOKEN=$(gh auth token -u "$GH_USER") gh release view "$TAG" -R "$REPO" >/dev/null 2>&1; then
    echo "$TAG 已经发布过，先改 Info.plist 里的版本号" >&2; exit 1
  fi
fi

scripts/bundle.sh release
APP=build/Harbor.app
# 自签名才能保证更新后权限保留、Sparkle 校验签名一致；临时签名的包不发
codesign -dr - "$APP" 2>&1 | grep -q "certificate leaf" || { echo "没有用自签名证书签名，不发布" >&2; exit 1; }
BUILD=$(/usr/libexec/PlistBuddy -c "Print CFBundleVersion" "$APP/Contents/Info.plist")

OUT=build/release
rm -rf "$OUT" && mkdir -p "$OUT"
ZIP="Harbor-$VERSION.zip"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$OUT/$ZIP"
# 输出形如 sparkle:edSignature="…" length="…"
SIGNATURE=$("$SPARKLE_BIN/sign_update" --account dev.lakes.harbor "$OUT/$ZIP")
URL=${HARBOR_DOWNLOAD_PREFIX:-https://github.com/$REPO/releases/download/$TAG}/$ZIP
cat > "$OUT/appcast.xml" <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Harbor</title>
    <item>
      <title>Harbor $VERSION</title>
      <pubDate>$(LC_ALL=C date -u "+%a, %d %b %Y %H:%M:%S +0000")</pubDate>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>26.0</sparkle:minimumSystemVersion>
      <link>https://github.com/$REPO/releases/tag/$TAG</link>
      <enclosure url="$URL" type="application/octet-stream" $SIGNATURE />
    </item>
  </channel>
</rss>
XML
echo "已生成 $OUT/$ZIP 和 $OUT/appcast.xml（$VERSION，构建号 $BUILD）"
(( LOCAL )) && exit 0

GH_TOKEN=$(gh auth token -u "$GH_USER") gh release create "$TAG" "$OUT/$ZIP" "$OUT/appcast.xml" \
  -R "$REPO" --target "$(git rev-parse HEAD)" --title "Harbor $VERSION" --generate-notes
echo "已发布 https://github.com/$REPO/releases/tag/$TAG"
