#!/usr/bin/env bash
# 本地质量门禁：静态分析 + 单元测试。在仓库根目录运行。
#
# 用法：
#   ./scripts/check.sh
# 可选环境变量 FLUTTER_BIN 指定 flutter 可执行（默认用 /c/src/flutter/bin/flutter，
# 即与发版构建一致的 bash 脚本，避免在 Windows 上 flutter.bat 退出挂死）。
#
# analyze / test 均为纯 Dart，不需要 JDK / Android SDK，跑得很快。
set -euo pipefail
cd "$(dirname "$0")/.."

FLUTTER="${FLUTTER_BIN:-/c/src/flutter/bin/flutter}"

echo "==> flutter pub get"
"$FLUTTER" pub get

echo "==> flutter analyze"
"$FLUTTER" analyze

echo "==> flutter test"
"$FLUTTER" test

echo "✅ 静态分析 + 单元测试全部通过"
