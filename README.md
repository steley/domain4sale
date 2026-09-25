# 域名出售页（Domain Sale Page）

纯静态方案：**没有后端、没有数据库进程**，nginx 托管静态文件即可。
用 Excel 维护「域名 / 价格」，粘贴进来跑一条命令生成 `domains.json`，
页面 JS 根据访问的域名自动显示标题和价格。

## 目录结构

```
domain-sale/
├── data/
│   └── domains.tsv             # ← 你的数据：从 Excel 直接粘贴（维护数据只碰这个文件）
├── scripts/
│   ├── build_json.py           # domains.tsv → public/data/domains.json
│   ├── issue_certs.sh          # HTTPS 方案A：acme.sh 批量签发证书（自动分组/续期）
│   └── ask_server.py           # HTTPS 方案B：Caddy 签发白名单接口
├── public/                     # 整个目录 = 网站根目录（上传到 VPS）
│   ├── index.html
│   ├── css/style.css
│   ├── js/app.js               # CONTACT_EMAIL 在这里改
│   └── data/domains.json       # 自动生成的产物
└── deploy/
    ├── nginx-domain-sale.conf        # nginx：HTTP 版（签证书时先用它）
    ├── nginx-domain-sale-https.conf  # nginx：HTTPS 版（证书签好后切换）
    ├── Caddyfile                     # caddy：自动 HTTPS（与 nginx 二选一）
    └── domain-sale-ask.service       # caddy 方案配套的 systemd 服务
```

## 一、维护数据（日常只做这一步）

1. 打开 `data/domains.tsv`，从 Excel 里复制「域名、价格」两列，直接粘贴保存。
2. 运行：

```bash
python3 scripts/build_json.py
```

格式要求（都很宽容）：
- Excel 直接复制粘贴（制表符分隔）即可；另存为的 CSV 也能识别。
- 有没有表头都行（`domain / price` 表头自动跳过）。
- 价格里的 `$`、千位逗号、`USD` 会自动去掉（`$2,500.00` → 2500）。
- **价格留空的域名不出现在 JSON 里 → 页面显示 "Make an offer"**。
- 域名自动转小写、去掉 `www.`。中文域名（IDN）请填 punycode 形式（`xn--…`）。

本地预览：

```bash
python3 -m http.server 8000 -d public
# 浏览器打开 http://localhost:8000/?domain=example.com
# ?domain= 参数可以模拟任意域名，方便测试
```

## 二、部署到 Ubuntu VPS

```bash
# 本机：上传网站文件
rsync -av --delete public/ root@你的VPS_IP:/var/www/domain-sale/public/

# VPS 上：
apt update && apt install -y nginx
cp /路径/deploy/nginx-domain-sale.conf /etc/nginx/sites-available/domain-sale
ln -sf /etc/nginx/sites-available/domain-sale /etc/nginx/sites-enabled/domain-sale
rm -f /etc/nginx/sites-enabled/default
nginx -t && systemctl reload nginx
```

然后域名的 A 记录都指向这台 VPS 的 IP 即可。
所有域名共用这一个 nginx 站点（catch-all），**不需要逐域名配置**。

## 三、更新价格

Excel 里改好 → 粘贴到 `data/domains.tsv` → `python3 scripts/build_json.py`
→ 把新的 `public/data/domains.json` 传到 VPS。

（也可以把整个项目放到 VPS 上直接跑脚本。）
浏览器对 JSON 缓存 5 分钟，改完最多等 5 分钟生效（强刷 Ctrl+F5 立即生效）。

## 四、修改联系邮箱

编辑 `public/js/app.js` 顶部：

```js
const CONTACT_EMAIL = "you@example.com";
```

改完重新上传 `app.js`。买家点击按钮后会带着预设主题（Purchase inquiry for 域名）给你发邮件。

## 五、页面显示逻辑

| 情况 | 标题 / H1 | 价格区 | 按钮 |
|---|---|---|---|
| 域名在 JSON 里且有价格 | `a.com for sale` | `$2,500 USD` | Buy Now |
| 域名不在 JSON 里 / 无价格 / IP 直接访问 | `a.com for sale`（IP 访问时保持默认文案） | Make an offer | Contact us |

## 六、HTTPS（nginx 和 Caddy 两种方案，二选一）

> 都基于 Let's Encrypt 免费证书。前提：域名的 A 记录已解析到 VPS。
> 多个域名是互相独立的不同域名，通配符证书不适用，所以要批量/自动签发。

### 方案 A：nginx + acme.sh 批量证书（保持现有架构）

脚本自动分组（Let's Encrypt 单证书上限 100 个域名）、自动检测变动（只重签有变化的组）、自动续期。在 VPS 上：

```bash
# 1. 按「二、部署」把 HTTP 版跑起来，并确认域名解析已生效

# 2. 安装 acme.sh（用 root，证书要写到 /etc/nginx/ssl）
sudo -i
curl https://get.acme.sh | sh -s email=你的邮箱

# 3. 批量签发（自动读 public/data/domains.json）
bash /var/www/domain-sale/scripts/issue_certs.sh
#    首次想先演练流程不出真证书的话:
#    ACME_SERVER=letsencrypt_test DRY_RUN=1 bash scripts/issue_certs.sh

# 4. 签发成功后切换到 HTTPS 配置
cp /var/www/domain-sale/deploy/nginx-domain-sale-https.conf \
   /etc/nginx/sites-available/domain-sale
nginx -t && systemctl reload nginx
```

- 续期全自动：acme.sh 自带 cron，每张证书到期前自动续期并 reload nginx
- 新增/删除域名：更新 `domains.tsv` → `build_json.py` → 重跑 `issue_certs.sh`
  （组内域名没变的证书直接跳过；域名减少时多余分组自动清理）
- 脚本支持 `DRY_RUN=1` 演练、`GROUP_SIZE`/`CERT_DIR` 等环境变量覆盖，详见脚本头部注释

### 方案 B：Caddy on_demand_tls（全自动，访客访问时自动签发）

用 Caddy 替代 nginx：任何域名第一次被访问时自动签发证书、自动续期，
新增域名零操作——ask 白名单接口会实时读取 `domains.json` 判断"是不是我的域名"。

```bash
# 1. 停掉 nginx（80/443 端口冲突，二选一）
systemctl disable --now nginx

# 2. 安装 Caddy（官方 apt 源）
apt install -y debian-keyring debian-archive-keyring apt-transport-https curl
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
  | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
  | tee /etc/apt/sources.list.d/caddy-stable.list
apt update && apt install -y caddy

# 3. 启动 ask 白名单接口（只监听本机 127.0.0.1:5555，外部不可访问）
cp /var/www/domain-sale/deploy/domain-sale-ask.service /etc/systemd/system/
systemctl daemon-reload && systemctl enable --now domain-sale-ask

# 4. 启用站点配置
cp /var/www/domain-sale/deploy/Caddyfile /etc/caddy/Caddyfile
systemctl reload caddy
```

- 整个项目（含 `scripts/`、`deploy/`）上传到 `/var/www/domain-sale`，网站根目录
  默认 `/var/www/domain-sale/public`（Caddyfile 里可改）
- 更新价格数据后**无需重启任何东西**：ask 接口按文件修改时间自动重新加载白名单


## 七、常见问题

- **直接双击 index.html（file://）打开，页面不对？** `file://` 下浏览器拿不到域名、也读取不了
  `domains.json`，所以只显示通用文案。这是正常降级：线上走 `http(s)://` 访问（或本地
  `python3 -m http.server 8000 -d public`）即一切正常。
- **标题/价格没变？** 强制刷新（Ctrl+F5）；或等 5 分钟缓存过期。
- **想测试某个域名效果？** 线上/本地都可用 `?domain=xxx.com` 参数。
- **脚本报“无效域名”？** 检查该行是否有多余文字或全角字符；中文域名需转 punycode。
