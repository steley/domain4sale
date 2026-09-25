#!/usr/bin/env bash
# nginx 方案：用 acme.sh 把 domains.json 里的域名批量签发成多张证书。
# Let's Encrypt 单证书最多 100 个域名，超出数量脚本自动分组、
# 自动检测变动（只重签有变化的组）、自动续期（acme.sh 自带 cron）。
# 个别组签发失败不中断整批：失败组列入清单、退出码非零，重跑可续签。
#
# 用法（在 VPS 上以 root 运行；域名 A 记录需已解析到本机）:
#   curl https://get.acme.sh | sh -s email=你的邮箱
#   bash scripts/issue_certs.sh
#
# 可用环境变量覆盖默认值:
#   DOMAIN_FILE  域名来源，默认 <项目>/public/data/domains.json
#   WEBROOT      acme 验证目录，默认 /var/www/domain4sale/public
#   CERT_DIR     证书输出目录，默认 /etc/nginx/ssl/domain4sale
#   GROUP_SIZE   每张证书的域名数，默认 100（Let's Encrypt 上限）
#   ACME_SERVER  CA，默认 letsencrypt；首次验证流程可先用 letsencrypt_test
#   DRY_RUN      设为 1 只打印将要执行的动作，不实际签发
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PROJECT_DIR=$(dirname "$SCRIPT_DIR")
DOMAIN_FILE="${DOMAIN_FILE:-$PROJECT_DIR/public/data/domains.json}"
WEBROOT="${WEBROOT:-/var/www/domain4sale/public}"
CERT_DIR="${CERT_DIR:-/etc/nginx/ssl/domain4sale}"
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
while IFS= read -r d; do
  if [ -n "$d" ]; then DOMAINS+=("$d"); fi
done \
  < <(python3 -c 'import json,sys; print("\n".join(sorted(json.load(open(sys.argv[1])))))' "$DOMAIN_FILE")

TOTAL=${#DOMAINS[@]}
if [ "$TOTAL" -eq 0 ]; then
  echo "✗ ${DOMAIN_FILE} 里没有域名" >&2
  exit 1
fi

mkdir -p "$CERT_DIR"

# 签发一组并安装到 $CERT_DIR/group-<NN>/，成功后写入组名单和 CA 记录。
# 调用方在 if 条件中调用本函数，因此函数内 set -e 已关闭——
# 失败一律显式 `|| return 1`，由调用方统一记录失败组。
issue_and_install() {
  local nn="$1"
  shift
  local primary="$1"
  local manifest="$CERT_DIR/group-$nn.domains"
  local cafile="$CERT_DIR/group-$nn.ca"

  local args=(--server "$ACME_SERVER" --webroot "$WEBROOT" --keylength ec-256)
  if [ -f "$manifest" ]; then
    args+=(--force)   # 该组此前签发过 → 域名列表有变，强制重签
  fi
  local d
  for d in "$@"; do args+=(-d "$d"); done
  run_acme --issue "${args[@]}" || return 1

  if [ "$DRY_RUN" = "1" ]; then
    return 0
  fi
  mkdir -p "$CERT_DIR/group-$nn"
  run_acme --install-cert -d "$primary" --ecc \
    --fullchain-file "$CERT_DIR/group-$nn/fullchain.pem" \
    --key-file "$CERT_DIR/group-$nn/privkey.pem" \
    --reloadcmd "systemctl reload nginx 2>/dev/null || nginx -s reload 2>/dev/null || true" || return 1
  printf '%s\n' "$@" > "$manifest"
  printf '%s\n' "$ACME_SERVER" > "$cafile"
}

# ── 分组签发 ────────────────────────────────────────────────
ISSUED=0
FAILED_GROUPS=()
for ((i = 0; i < TOTAL; i += GROUP_SIZE)); do
  GROUP=("${DOMAINS[@]:$i:$GROUP_SIZE}")
  NN=$(printf '%02d' $((i / GROUP_SIZE + 1)))
  MANIFEST="$CERT_DIR/group-$NN.domains"
  PRIMARY="${GROUP[0]}"

  # 域名列表、证书文件、CA 三者都没变 → 跳过
  if [ -f "$MANIFEST" ] \
     && [ "$(cat "$MANIFEST" 2>/dev/null)" = "$(printf '%s\n' "${GROUP[@]}")" ] \
     && [ -f "$CERT_DIR/group-$NN/fullchain.pem" ] \
     && [ "$(cat "$CERT_DIR/group-$NN.ca" 2>/dev/null)" = "$ACME_SERVER" ]; then
    continue
  fi

  echo "▶ 签发第 $NN 组: ${#GROUP[@]} 个域名（主域名 ${PRIMARY}）..."
  if issue_and_install "$NN" "${GROUP[@]}"; then
    ISSUED=$((ISSUED + 1))
  else
    echo "✗ 第 $NN 组签发/安装失败（主域名 ${PRIMARY}），继续处理后面的组" >&2
    FAILED_GROUPS+=("$NN")
  fi
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
      rm -rf "$dir" "$m" "$CERT_DIR/$base.ca"
      echo "ℹ 已清理多余的 ${dir}（域名数量减少）"
    fi
  fi
done

# ── 生成 nginx 配置（deploy/nginx-domain4sale-https.conf include 之）────────
# nginx 同一 server 块内的多张证书只按算法类型（RSA/ECDSA）选择，不按 SNI 选择，
# 因此必须每组域名一个 server 块（server_name 列出该组成员 + 该组证书），
# 外加一个 default_server 兜底块处理未知域名 / IP 访问。
rm -f "$CERT_DIR/certs.conf"   # 清理旧版产物，避免混淆

# 公共部分：被下面所有 443 server 块 include
COMMON="$CERT_DIR/common.conf"
{
  echo "root $WEBROOT;"
  echo "index index.html;"
  echo ""
  cat <<'EOF'
gzip on;
gzip_comp_level 5;
gzip_min_length 256;
gzip_types text/css application/javascript application/json image/svg+xml text/plain;

add_header Strict-Transport-Security "max-age=31536000" always;

location = /data/domains.json {
    add_header Cache-Control "public, max-age=300";
}

location / {
    try_files $uri $uri/ =404;
}
EOF
} > "$COMMON"

CONF="$CERT_DIR/servers.conf"
: > "$CONF"
FIRST_GROUP=""
for dir in "$CERT_DIR"/group-*; do
  [ -d "$dir" ] || continue
  base=$(basename "$dir")
  m="$CERT_DIR/$base.domains"
  [ -f "$m" ] || continue
  if [ -z "$FIRST_GROUP" ]; then FIRST_GROUP="$dir"; fi

  {
    echo "server {"
    echo "    listen 443 ssl;"
    echo "    listen [::]:443 ssl;"
    n=0; sn=""
    while IFS= read -r d; do
      sn="$sn $d"; n=$((n + 1))
      if [ $((n % 20)) -eq 0 ]; then echo "    server_name$sn;"; sn=""; fi
    done < "$m"
    if [ -n "$sn" ]; then echo "    server_name$sn;"; fi
    echo "    ssl_certificate     $dir/fullchain.pem;"
    echo "    ssl_certificate_key $dir/privkey.pem;"
    echo "    include $COMMON;"
    echo "}"
    echo ""
  } >> "$CONF"
done

if [ -n "$FIRST_GROUP" ]; then
  cat >> "$CONF" <<EOF
# 兜底块：未知域名 / IP 直接访问会落到这里。
# CA 不会给未收录的域名签发证书，因此这里用第一组证书顶上，
# 浏览器会提示"证书不匹配"，属预期行为（把它们录入 domains.tsv 即可解决）。
server {
    listen 443 ssl default_server;
    listen [::]:443 ssl default_server;
    ssl_certificate     $FIRST_GROUP/fullchain.pem;
    ssl_certificate_key $FIRST_GROUP/privkey.pem;
    include $COMMON;
}
EOF
fi

echo "✓ 完成: $TOTAL 个域名 / $TOTAL_GROUPS 张证书，本次新签 $ISSUED 张"
echo "  nginx 配置片段: ${CONF}（每组成员一个 server 块 + 兜底块）"
if [ "$DRY_RUN" = "1" ]; then
  echo "  （dry-run 模式，未实际签发；去掉 DRY_RUN=1 正式执行）"
elif [ "${#FAILED_GROUPS[@]}" -gt 0 ]; then
  echo "✗ 以下组签发/安装失败: ${FAILED_GROUPS[*]}" >&2
  echo "  已成功的组不受影响；排查（多为组内域名 DNS 未生效）后重跑本脚本即可续签" >&2
  exit 1
elif [ "$ISSUED" -gt 0 ]; then
  echo "  下一步: 启用 deploy/nginx-domain4sale-https.conf 并 reload"
fi
