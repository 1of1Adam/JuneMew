#!/bin/bash
#
# 把本机保管的 DeepSeek API key 混淆后注入 app 资源。
#
# 用法:
#   echo "sk-..." > ~/Documents/JuneMew-deepseek-key   # 一次性放好
#   scripts/gen-secrets.sh                              # 每次改 key 后重跑
#
# 产物 MewNotch/Resources/Secrets/deepseek.key.enc 已被 .gitignore,
# key 永远不进 git;XOR 混淆让 strings 扫不出 sk- 前缀。
# 文件不存在时 app 正常构建运行,只是翻译功能不启用。
#
# ⚠️ 混淆不是加密:下载 .app 的人有耐心逆向仍能取出 key。
#    公开分发前要么接受这一风险(key 可随时作废重开),要么改用
#    设置页让用户自填 key。

set -euo pipefail
cd "$(dirname "$0")/.."

KEY_FILE="$HOME/Documents/JuneMew-deepseek-key"
OUT_DIR="MewNotch/Resources/Secrets"
OUT="$OUT_DIR/deepseek.key.enc"

if [ ! -f "$KEY_FILE" ]; then
    echo "==> $KEY_FILE 不存在,跳过(翻译功能将不启用)"
    exit 0
fi

mkdir -p "$OUT_DIR"

python3 - "$KEY_FILE" "$OUT" <<'PYEOF'
import sys

# 与 SecretVault.swift 中的 pad 严格一致
PAD = bytes([
    0xaa, 0xd8, 0x3a, 0x72, 0x85, 0x1f, 0x00, 0xcf,
    0xc2, 0xa6, 0xb4, 0x62, 0xa9, 0xc5, 0xc7, 0x97,
    0x87, 0xa3, 0x04, 0xef, 0x4b, 0x18, 0x22, 0xcb,
    0x48, 0x53, 0xcd, 0xc6, 0xfa, 0xe4, 0x9d, 0x92,
])

key = open(sys.argv[1]).read().strip().encode()
if not key:
    sys.exit("key 文件为空")
blob = bytes(b ^ PAD[i % len(PAD)] for i, b in enumerate(key))
open(sys.argv[2], 'wb').write(blob)
print(f"==> 已写入 {sys.argv[2]} ({len(blob)} bytes)")
PYEOF
