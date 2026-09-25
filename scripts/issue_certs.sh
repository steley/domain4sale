#!/usr/bin/env bash
# nginx 方案：用 acme.sh 把 domains.json 里的域名批量签发成多张证书。
# Let's Encrypt 单证书最多 100 个域名，1500 个 → 15 张，脚本自动分组、
# 自动检测变动（只重签有变化的组）、自动续期（acme.sh 自带 cron）。
#
# 用法（在 VPS 上以 root 运行；域名 A 记录需已解析到本机）:
#   curl https://get.acme.sh | sh -s email=你的邮箱
#   bash scripts/issue_certs.sh
#
# 可用环境变量覆盖默认值:
#   DOMAIN_FILE  域名来源，默认 <项目>/public/data/domains.json
#   WEBROOT      acme 验证目录，默认 /var/www/domain-sale/public
#   CERT_DIR     证书输出目录，默认 /etc/nginx/ssl/domain-sale
#   GROUP_SIZE   每张证书的域名数，默认 100（Let's Encrypt 上限）
#   ACME_SERVER  CA，默认 letsencrypt；首次验证流程可先用 letsencrypt_test
#   DRY_RUN      设为 1 只打印将要执行的动作，不实际签发
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PROJECT_DIR=$(dirname "$SCRIPT_DIR")
DOMAIN_FILE="${DOMAIN_FILE:-$PROJECT_DIR/public/data/domains.json}"
WEBROOT="${WEBROOT:-/var/www/domain-sale/public}"
CERT_DIR="${CERT_DIR:-/etc/nginx/ssl/domain-sale}"
GROUP_SIZE="${GROUP_SIZE:-100}"
ACME_SERVER="${ACME_SERVER:-letsencrypt}"
ACME="${ACME:-$HOME/.acme.sh/acme.sh}"

DRY_RUN="${DRY_RUN:-0}"
run_acme() {
  if [ "$DRY_RUN" = "1" ]; then
    echo "  [dry-run] acme.sh $*"
  else
    "$ACME" "$@"
  fi
}

if [ ! -x "$ACME" ]; then
  echo "✗ 找不到 acme.sh（${ACME}）" >&2
  echo "  先安装: curl https://get.acme.sh | sh -s email=你的邮箱" >&2
  exit 1
fi
if [ ! -f "$DOMAIN_FILE" ]; then
  echo "✗ 找不到 ${DOMAIN_FILE}，先运行 python3 scripts/build_json.py" >&2
  exit 1
fi

# 从 domains.json 读取域名列表（复用 build_json.py 的清洗结果）
DOMAINS=()
while IFS= read -r d; do [ -n "$d" ] && DOMAINS+=("$d"); done \
  < <(python3 -c 'import json,sys; print("\n".join(sorted(json.load(open(sys.argv[1])))))' "$DOMAIN_FILE")

TOTAL=${#DOMAINS[@]}
if [ "$TOTAL" -eq 0 ]; then
  echo "✗ $DOMAIN_FILE 里没有域名" >&2
  exit 1
fi

mkdir -p "$CERT_DIR"
touch "$CERT_DIR/certs.conf"   # 保证 nginx include 引用的文件始终存在

# ── 分组签发 ────────────────────────────────────────────────
ISSUED=0
for ((i = 0; i < TOTAL; i += GROUP_SIZE)); do
  GROUP=("${DOMAINS[@]:$i:$GROUP_SIZE}")
  NN=$(printf '%02d' $((i / GROUP_SIZE + 1)))
  MANIFEST="$CERT_DIR/group-$NN.domains"

  printf '%s\n' "${GROUP[@]}" > "$MANIFEST.new"
  if [ -f "$MANIFEST" ] && cmp -s "$MANIFEST" "$MANIFEST.new" \
     && [ -f "$CERT_DIR/group-$NN/fullchain.pem" ]; then
    rm "$MANIFEST.new"
    continue   # 组内域名没变且证书已存在，跳过
  fi

  PRIMARY="${GROUP[0]}"
  echo "▶ 签发第 $NN 组: ${#GROUP[@]} 个域名（主域名 ${PRIMARY}）..."
  ARGS=("--server" "$ACME_SERVER" "--webroot" "$WEBROOT" "--keylength" "ec-256")
  if [ -f "$MANIFEST" ]; then
    ARGS+=("--force")   # 组内域名列表变了，强制重签
  fi
  for d in "${GROUP[@]}"; do ARGS+=("-d" "$d"); done
  run_acme --issue "${ARGS[@]}"

  if [ "$DRY_RUN" != "1" ]; then
    mkdir -p "$CERT_DIR/group-$NN"
    run_acme --install-cert "$PRIMARY" --ecc \
      --fullchain-file "$CERT_DIR/group-$NN/fullchain.pem" \
      --key-file "$CERT_DIR/group-$NN/privkey.pem" \
      --reloadcmd "systemctl reload nginx 2>/dev/null || nginx -s reload 2>/dev/null || true"
    mv "$MANIFEST.new" "$MANIFEST"
  fi
  ISSUED=$((ISSUED + 1))
done

# ── 清理多余分组（域名数量减少时）─────────────────────────
TOTAL_GROUPS=$(( (TOTAL + GROUP_SIZE - 1) / GROUP_SIZE ))
for dir in "$CERT_DIR"/group-*; do
  [ -d "$dir" ] || continue
  base=$(basename "$dir")
  n=${base#group-}
  if [ "$((10#$n))" -gt "$TOTAL_GROUPS" ]; then
    if [ "$DRY_RUN" = "1" ]; then
      echo "  [dry-run] 清理多余的 $dir"
    else
      m="$CERT_DIR/$base.domains"
      if [ -f "$m" ]; then
        "$ACME" --remove -d "$(head -n1 "$m")" --ecc >/dev/null 2>&1 || true
      fi
      rm -rf "$dir" "$m"
      echo "ℹ 已清理多余的 ${dir}（域名数量减少）"
    fi
  fi
done

# ── 生成 nginx 引用片段（deploy/nginx-domain-sale-https.conf 会 include 它）──
CONF="$CERT_DIR/certs.conf"
: > "$CONF"
for dir in "$CERT_DIR"/group-*; do
  [ -d "$dir" ] || continue
  { echo "ssl_certificate     $dir/fullchain.pem;"
    echo "ssl_certificate_key $dir/privkey.pem;"; } >> "$CONF"
done

echo "✓ 完成: $TOTAL 个域名 / $TOTAL_GROUPS 张证书，本次新签 $ISSUED 张"
echo "  nginx 引用片段: $CONF"
if [ "$DRY_RUN" = "1" ]; then
  echo "  （dry-run 模式，未实际签发；去掉 DRY_RUN=1 正式执行）"
elif [ "$ISSUED" -gt 0 ]; then
  echo "  下一步: 启用 deploy/nginx-domain-sale-https.conf"
fi
