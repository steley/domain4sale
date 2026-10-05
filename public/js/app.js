/* ====== 配置 ====== */
/* 联系邮箱只改 index.html 里按钮的 href（mailto:you@example.com），
   JS 会自动从那里读取，无需在此重复配置 */
/* 价格数据地址（相对站点根目录） */
const DATA_URL = "data/domains.json";

/* ====== 以下为逻辑代码，一般无需修改 ====== */

const $title = document.getElementById("domain-title");
const $tagline = document.getElementById("tagline");
const $priceBox = document.getElementById("price-box");
const $price = document.getElementById("price");
const $priceUsd = document.getElementById("price-usd");
const $btn = document.getElementById("contact-btn");
/* 联系邮箱单一来源：index.html 按钮的 href（mailto:xxx?subject=… → xxx）。
   必须在下方 applyPrice() 覆写 href 之前取值 */
const CONTACT_EMAIL = $btn.href.slice(7).split("?")[0];

function normalizeHost(raw) {
  let h = (raw || "").toLowerCase().trim();
  h = h.replace(/^https?:\/\//, "").split("/")[0].split("?")[0];
  h = h.replace(/:\d+$/, "");   // 去端口
  h = h.replace(/^www\./, "");  // www.a.com → a.com
  h = h.replace(/\.$/, "");     // 去结尾的点
  return h;
}

function isIPAddress(h) {
  if (h.includes(":")) return true; // IPv6
  return /^\d{1,3}(\.\d{1,3}){3}$/.test(h);
}

function formatUSD(n) {
  const opts = Number.isInteger(n)
    ? { minimumFractionDigits: 0, maximumFractionDigits: 0 }
    : { minimumFractionDigits: 2, maximumFractionDigits: 2 };
  return "$" + n.toLocaleString("en-US", opts);
}

/* 设置标题区（h1 / title / 描述文字） */
function applyHost(host) {
  if (!host || isIPAddress(host)) return; // IP 访问保持默认文案
  document.title = `${host} for sale`;
  $title.textContent = `${host} for sale`;
  $tagline.textContent = `The premium domain ${host} is available for purchase. Send us your offer today.`;
}

/* 设置价格区和按钮 */
function applyPrice(price, host) {
  if (price !== null && price !== undefined) {
    $priceBox.classList.add("has-price");
    $price.textContent = formatUSD(price);
    $priceUsd.hidden = false;
    $btn.textContent = "Buy Now";
  } else {
    $priceBox.classList.remove("has-price");
    $price.textContent = "Make an offer";
    $priceUsd.hidden = true;
    $btn.textContent = "Contact us";
  }
  const domainText = host ? `the domain "${host}"` : "this domain";
  const subject = `Purchase inquiry for ${host || "your domain"}`;
  const body = `Hi,\n\nI am interested in purchasing ${domainText}.\n\nMy offer: \n\nBest regards`;
  $btn.href = `mailto:${CONTACT_EMAIL}?subject=${encodeURIComponent(subject)}&body=${encodeURIComponent(body)}`;
}

// ?domain=xxx.com 查询参数可覆盖实际域名，仅限本地测试用（file://、localhost、IP 访问）；
// 正式域名上放任覆盖的话，任何人都能把页面渲染成任意 "xxx.com for sale"
const hn = location.hostname;
const override = (!hn || hn === "localhost" || hn.endsWith(".localhost") || isIPAddress(hn))
  ? new URLSearchParams(location.search).get("domain")
  : null;
const host = normalizeHost(override || location.hostname);

(async () => {
  if (host) {
    applyHost(host);
    try {
      const r = await fetch(DATA_URL);
      const data = r.ok ? await r.json() : {};
      applyPrice(
        Object.prototype.hasOwnProperty.call(data, host) ? data[host] : null,
        host
      );
    } catch {
      // 数据加载失败时按"未定价"降级，并留下排查线索
      console.warn("[domain4sale] Failed to load domains.json — falling back to \"Make an offer\"");
      applyPrice(null, host);
    }
  } else {
    // file:// 直接打开等无域名的场景：显示通用文案
    applyPrice(null, "");
  }
})();

const $year = document.getElementById("year");
if ($year) $year.textContent = new Date().getFullYear();

if (CONTACT_EMAIL === "you@example.com") {
  console.warn("[domain4sale] CONTACT_EMAIL is still the placeholder — edit public/js/app.js");
}
