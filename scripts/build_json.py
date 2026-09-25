#!/usr/bin/env python3
"""把从 Excel 粘贴的「域名 价格」两列转换为前端使用的 domains.json。

用法:
    python3 scripts/build_json.py                     # 读 data/domains.tsv
    python3 scripts/build_json.py 某文件.csv           # 指定输入（制表符/逗号分隔均可）
    python3 scripts/build_json.py in.tsv -o out.json  # 指定输出路径
"""
import argparse
import csv
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DEFAULT_INPUT = ROOT / "data" / "domains.tsv"
DEFAULT_OUTPUT = ROOT / "public" / "data" / "domains.json"

# 中文等非 ASCII 域名请先转成 punycode（xn--…）再粘贴
DOMAIN_RE = re.compile(r"^(?=.{1,253}$)([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$")
HEADER_NAMES = {"domain", "domains", "name", "域名"}


def clean_domain(raw: str) -> str:
    d = raw.strip().lstrip("\ufeff").lower()
    d = re.sub(r"^https?://", "", d)          # 粘贴成完整 URL 也能处理
    d = d.split("/", 1)[0].split("?", 1)[0]   # 去掉路径和参数
    d = d.split(":", 1)[0]                    # 去掉端口
    if d.startswith("www."):
        d = d[4:]
    return d.rstrip(".")


def parse_price(raw: str):
    """返回数字；空值或 0 返回 None（0 视为未定价）。容忍 $、千位逗号、USD 等符号。"""
    p = re.sub(r"(?i)usd|cny|rmb", "", raw)
    p = p.replace(",", "").replace("$", "").replace("¥", "").replace("￥", "").strip()
    if not p:
        return None
    try:
        value = float(p)
    except ValueError:
        raise ValueError(f"无法识别的价格 “{raw.strip()}”")
    if value < 0:
        raise ValueError(f"价格不能为负数 “{raw.strip()}”")
    if value == 0:
        return None
    return int(value) if value.is_integer() else round(value, 2)


def main() -> int:
    parser = argparse.ArgumentParser(description="domains.tsv -> domains.json")
    parser.add_argument("input", nargs="?", default=str(DEFAULT_INPUT),
                        help="输入文件，默认 data/domains.tsv")
    parser.add_argument("-o", "--output", default=str(DEFAULT_OUTPUT),
                        help="输出文件，默认 public/data/domains.json")
    args = parser.parse_args()

    in_path, out_path = Path(args.input), Path(args.output)
    if not in_path.exists():
        print(f"✗ 找不到输入文件: {in_path}", file=sys.stderr)
        return 1

    result = {}
    total = no_price = bad = dup = 0
    for lineno, line in enumerate(in_path.read_text(encoding="utf-8-sig").splitlines(), 1):
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        total += 1
        # Excel 直接粘贴出来是制表符分隔；另存为的 CSV 用 csv 模块解析（正确处理引号）
        parts = line.split("\t") if "\t" in line else next(csv.reader([line]))
        domain = clean_domain(parts[0])
        if domain in HEADER_NAMES:
            continue  # 表头行
        if not DOMAIN_RE.match(domain):
            hint = "（中文域名请使用 punycode 形式 xn--…）" if re.search(r"[^\x00-\x7f]", domain) else ""
            print(f"  ! 第 {lineno} 行跳过：无效域名 “{parts[0].strip()}”{hint}", file=sys.stderr)
            bad += 1
            continue
        try:
            price = parse_price(parts[1]) if len(parts) > 1 else None
        except ValueError as e:
            print(f"  ! 第 {lineno} 行跳过：{e}", file=sys.stderr)
            bad += 1
            continue
        if price is None:
            # 没填价格的域名不写入 JSON，页面会显示 Make an offer
            no_price += 1
            continue
        if domain in result:
            dup += 1
            print(f"  ! 第 {lineno} 行：{domain} 重复，覆盖旧价格 {result[domain]} → {price}",
                  file=sys.stderr)
        result[domain] = price

    out_path.parent.mkdir(parents=True, exist_ok=True)
    with out_path.open("w", encoding="utf-8") as f:
        json.dump(result, f, ensure_ascii=False, indent=2, sort_keys=True)
        f.write("\n")

    print(f"✓ 已生成 {out_path}")
    print(f"  数据行 {total} | 导入 {len(result)} | 无价格 {no_price} | 重复 {dup} | 异常 {bad}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
