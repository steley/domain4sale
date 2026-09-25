/* ====== 配置 ====== */
/* 改成你的邮箱：买家点击按钮后会向这个邮箱发邮件 */
const CONTACT_EMAIL = "you@example.com";

/* ====== 以下为逻辑代码，一般无需修改 ====== */

const $title = document.getElementById("domain-title");
const $tagline = document.getElementById("tagline");
const $priceBox = document.getElementById("price-box");
const $price = document.getElementById("price");
const $priceUsd = document.getElementById("price-usd");
const $btn = document.getElementById("contact-btn");

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
  if (price != null) {
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

// ?domain=xxx.com 查询参数可覆盖实际域名，方便本地测试
const override = new URLSearchParams(location.search).get("domain");
const host = normalizeHost(override || location.hostname);

if (host) {
  applyHost(host);
  fetch("data/domains.json")
    .then((r) => (r.ok ? r.json() : {}))
    .then((data) => applyPrice(
      Object.prototype.hasOwnProperty.call(data, host) ? data[host] : null,
      host
    ))
    .catch(() => applyPrice(null, host));
} else {
  // file:// 直接打开等无域名的场景：显示通用文案
  applyPrice(null, "");
}

document.getElementById("year").textContent = new Date().getFullYear();

if (CONTACT_EMAIL === "you@example.com") {
  console.warn("[domain-sale] CONTACT_EMAIL is still the placeholder — edit public/js/app.js");
}
