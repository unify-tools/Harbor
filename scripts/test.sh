#!/bin/zsh
# 只装了命令行工具（没装 Xcode）时，Swift Testing 不在默认搜索路径上，这里手动补上。
# 装了 Xcode 之后直接 swift test 即可。
set -euo pipefail
cd "$(dirname "$0")/.."
CLT=/Library/Developer/CommandLineTools/Library/Developer
if [[ -d $CLT/Frameworks/Testing.framework ]] && ! xcode-select -p | grep -q Xcode.app; then
  swift test \
    -Xswiftc -F -Xswiftc $CLT/Frameworks \
    -Xlinker -F -Xlinker $CLT/Frameworks \
    -Xlinker -rpath -Xlinker $CLT/Frameworks \
    -Xlinker -rpath -Xlinker $CLT/usr/lib "$@"
else
  swift test "$@"
fi
