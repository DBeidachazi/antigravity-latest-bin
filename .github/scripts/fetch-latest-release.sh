#!/usr/bin/env bash

set -euo pipefail

DOWNLOAD_PAGE_URL="${DOWNLOAD_PAGE_URL:-https://antigravity.google/download/}"
UPDATER_API_URL="${UPDATER_API_URL:-https://antigravity-hub-auto-updater-974169037036.us-central1.run.app/releases}"
MIN_TARBALL_SIZE="${MIN_TARBALL_SIZE:-52428800}"

if [[ ! "$MIN_TARBALL_SIZE" =~ ^[0-9]+$ ]]; then
  echo "错误: MIN_TARBALL_SIZE 必须是非负整数" >&2
  exit 2
fi

python3 - "$DOWNLOAD_PAGE_URL" "$UPDATER_API_URL" "$MIN_TARBALL_SIZE" <<'PYEOF'
import email.utils
import json
import os
import re
import sys
import time
import urllib.error
import urllib.request

download_page_url, updater_api_url, min_size_raw = sys.argv[1:4]
min_size = int(min_size_raw)

GCS_BASE = "https://storage.googleapis.com/antigravity-public/antigravity-hub"
URL_RE = re.compile(
    r"https://storage\.googleapis\.com/antigravity-public/antigravity-hub/"
    r"([0-9]+(?:\.[0-9]+)+)-([0-9]+)/linux-(x64|arm)/Antigravity\.tar\.gz"
)
VER_RE = re.compile(r"^[0-9]+(?:\.[0-9]+)+$")
ID_RE = re.compile(r"^[0-9]+$")


def fetch_bytes(url: str, method: str = "GET", attempts: int = 3):
    last_err = None
    for attempt in range(1, attempts + 1):
        req = urllib.request.Request(
            url,
            method=method,
            headers={"User-Agent": "antigravity-latest-bin-aur-updater/1.0"},
        )
        try:
            with urllib.request.urlopen(req, timeout=30) as resp:
                data = b"" if method == "HEAD" else resp.read()
                return resp.status, resp.headers, data
        except (urllib.error.URLError, TimeoutError, OSError) as exc:
            last_err = exc
            if attempt < attempts:
                time.sleep(attempt * 3)
    raise RuntimeError(f"请求失败 ({method} {url}): {last_err}")


def parse_version_tuple(version: str) -> tuple[int, ...]:
    return tuple(int(part) for part in version.split("."))


def check_tarball(url: str) -> tuple[bool, int, float]:
    try:
        status, headers, _ = fetch_bytes(url, method="HEAD", attempts=3)
    except RuntimeError as exc:
        print(f"警告: {exc}", file=sys.stderr)
        return False, 0, 0.0

    if status != 200:
        return False, 0, 0.0

    try:
        size = int(headers.get("Content-Length", "0"))
    except ValueError:
        size = 0

    if size < min_size:
        print(
            f"警告: {url} Content-Length={size} 小于最低要求 {min_size}",
            file=sys.stderr,
        )
        return False, size, 0.0

    last_mod_raw = headers.get("Last-Modified")
    last_mod_ts = 0.0
    if last_mod_raw:
        try:
            last_mod_ts = email.utils.parsedate_to_datetime(last_mod_raw).timestamp()
        except (TypeError, ValueError):
            last_mod_ts = 0.0

    return True, size, last_mod_ts


candidates: dict[tuple[str, str], int] = {}

# 1. 解析官网下载页中的 Linux tarball 链接
try:
    _, _, page_bytes = fetch_bytes(download_page_url, method="GET", attempts=3)
    page_html = page_bytes.decode("utf-8", errors="replace")
    page_arches: dict[tuple[str, str], set[str]] = {}
    for ver, build_id, arch in URL_RE.findall(page_html):
        if VER_RE.match(ver) and ID_RE.match(build_id):
            page_arches.setdefault((ver, build_id), set()).add(arch)
    for pair, arches in page_arches.items():
        if {"x64", "arm"}.issubset(arches):
            candidates[pair] = max(candidates.get(pair, 0), 2)
            print(f"下载页发现候选版本: {pair[0]} (build {pair[1]})", file=sys.stderr)
except Exception as exc:
    print(f"警告: 解析下载页失败: {exc}", file=sys.stderr)

# 2. 查询官方自动更新 API 作为兜底和交叉验证
try:
    _, _, api_bytes = fetch_bytes(updater_api_url, method="GET", attempts=3)
    releases = json.loads(api_bytes.decode("utf-8"))
    if isinstance(releases, list):
        for idx, item in enumerate(releases[:3]):
            ver = str(item.get("version", "")).strip()
            build_id = str(item.get("execution_id", "")).strip()
            if VER_RE.match(ver) and ID_RE.match(build_id):
                # 越靠前优先级越高（作为相同版本号时的辅助判断）
                candidates[(ver, build_id)] = max(candidates.get((ver, build_id), 0), 1 if idx == 0 else 0)
                if idx == 0:
                    print(f"Updater API 最新候选版本: {ver} (build {build_id})", file=sys.stderr)
except Exception as exc:
    print(f"警告: 查询 Updater API 失败: {exc}", file=sys.stderr)

if not candidates:
    print("错误: 未能从官网下载页或 Updater API 获取任何有效候选版本", file=sys.stderr)
    sys.exit(1)

verified = []
# 先按版本号降序分组验证，避免对旧版本发多余请求
sorted_pairs = sorted(
    candidates.keys(),
    key=lambda pair: (parse_version_tuple(pair[0]), candidates[pair]),
    reverse=True,
)

top_verified_version: tuple[int, ...] | None = None
for ver, build_id in sorted_pairs:
    ver_tuple = parse_version_tuple(ver)
    if top_verified_version is not None and ver_tuple < top_verified_version:
        break

    x86_64_url = f"{GCS_BASE}/{ver}-{build_id}/linux-x64/Antigravity.tar.gz"
    aarch64_url = f"{GCS_BASE}/{ver}-{build_id}/linux-arm/Antigravity.tar.gz"

    ok_x64, size_x64, ts_x64 = check_tarball(x86_64_url)
    ok_arm, size_arm, ts_arm = check_tarball(aarch64_url)
    if ok_x64 and ok_arm:
        top_verified_version = ver_tuple
        verified.append(
            {
                "version": ver,
                "build_id": build_id,
                "x86_64_url": x86_64_url,
                "aarch64_url": aarch64_url,
                "size_x64": size_x64,
                "size_arm": size_arm,
                "ts": max(ts_x64, ts_arm),
                "priority": candidates[(ver, build_id)],
            }
        )

if not verified:
    print("错误: 所有候选版本的 x86_64/aarch64 安装包 HEAD 校验均未通过", file=sys.stderr)
    sys.exit(1)

best = max(
    verified,
    key=lambda item: (parse_version_tuple(item["version"]), item["ts"], item["priority"]),
)

if not VER_RE.match(best["version"]) or not ID_RE.match(best["build_id"]):
    print(f"错误: 非法的版本信息: {best}", file=sys.stderr)
    sys.exit(1)

print(
    f"确认最新版本: {best['version']} (build {best['build_id']}), "
    f"x86_64={best['size_x64']} bytes, aarch64={best['size_arm']} bytes",
    file=sys.stderr,
)

lines = [
    f"version={best['version']}",
    f"build_id={best['build_id']}",
    f"x86_64_url={best['x86_64_url']}",
    f"aarch64_url={best['aarch64_url']}",
]

github_output = os.environ.get("GITHUB_OUTPUT")
if github_output:
    with open(github_output, "a", encoding="utf-8") as fh:
        for line in lines:
            fh.write(line + "\n")
else:
    for line in lines:
        print(line)
PYEOF
