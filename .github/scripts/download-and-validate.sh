#!/usr/bin/env bash

set -euo pipefail

if (( $# != 3 )); then
  echo "用法: $0 <下载地址> <输出文件> <架构名称>" >&2
  exit 2
fi

url="$1"
output="$2"
label="$3"
partial="${output}.part"
min_tarball_size="${MIN_TARBALL_SIZE:-52428800}"
retry_delay_base="${RETRY_DELAY_BASE:-15}"

if [[ ! "$min_tarball_size" =~ ^[0-9]+$ || ! "$retry_delay_base" =~ ^[0-9]+$ ]]; then
  echo "错误: MIN_TARBALL_SIZE 和 RETRY_DELAY_BASE 必须是非负整数" >&2
  exit 2
fi

mkdir -p "$(dirname "$output")"

for attempt in 1 2 3; do
  echo "=== 下载 ${label} (第 ${attempt}/3 次尝试) ==="
  rm -f "$output" "$partial"

  if curl --retry 3 --retry-delay 5 --retry-all-errors \
       --connect-timeout 30 --max-time 1800 -fL \
       "$url" -o "$partial"; then
    size=$(stat -c '%s' "$partial")
    echo "${label} 下载大小: ${size} bytes"

    if (( size < min_tarball_size )); then
      echo "错误: ${label} 只有 ${size} bytes，小于最低要求 ${min_tarball_size} bytes" >&2
    else
      list_file="${partial}.list"
      rm -f "$list_file"
      if ! tar -tzf "$partial" > "$list_file"; then
        echo "错误: ${label} tar.gz 归档损坏" >&2
      elif ! grep -Eq '^Antigravity-[^/]+/antigravity$' "$list_file"; then
        echo "错误: ${label} 缺少 Antigravity-*/antigravity 可执行文件" >&2
      else
        rm -f "$list_file"
        mv "$partial" "$output"
        echo "${label} 校验通过"
        exit 0
      fi
      rm -f "$list_file"
    fi
  else
    echo "错误: ${label} 下载失败" >&2
  fi

  rm -f "$partial"
  if (( attempt < 3 )); then
    sleep $((attempt * retry_delay_base))
  fi
done

exit 1
