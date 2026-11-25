#!/bin/zsh
# 一行命令安装（不用装 Xcode 命令行工具）：
#   curl -fsSL https://raw.githubusercontent.com/pine-chen/ai-boot-animations/main/claude/web-install.sh | zsh
# 从 GitHub Releases 下载编好的通用版程序（Apple 芯片 / Intel 都能用），再走 install.sh 安装
set -e
URL="https://github.com/pine-chen/ai-boot-animations/releases/latest/download/ClaudeBootAnimation.zip"
[[ "$(uname)" == Darwin ]] || { echo "只支持 macOS"; exit 1; }
MAJOR=$(sw_vers -productVersion | cut -d. -f1)
(( MAJOR >= 13 )) || { echo "需要 macOS 13 或更新，你的是 $(sw_vers -productVersion)"; exit 1; }
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
echo "⬇️  正在下载 Claude 开机动画（约 50MB）…"
if curl -fL --progress-bar -o "$TMP/pkg.zip" "$URL"; then
  ditto -x -k "$TMP/pkg.zip" "$TMP/pkg"
  zsh "$TMP/pkg/ClaudeBootAnimation/install.sh"
else
  echo "ℹ️  未找到 Release 预编译包，改为拉取 claude/ 源码现场编译安装…"
  command -v git >/dev/null || { echo "需要 git 或先在 GitHub Releases 上传 ClaudeBootAnimation.zip"; exit 1; }
  git clone --depth 1 --filter=blob:none --sparse https://github.com/pine-chen/ai-boot-animations.git "$TMP/repo"
  git -C "$TMP/repo" sparse-checkout set claude
  zsh "$TMP/repo/claude/install.sh"
fi
