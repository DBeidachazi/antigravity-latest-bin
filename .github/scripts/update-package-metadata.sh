#!/usr/bin/env bash

set -euo pipefail

if (( $# != 4 )); then
  echo "用法: $0 <版本号> <Build ID> <x86_64 BLAKE2b> <aarch64 BLAKE2b>" >&2
  exit 2
fi

version="$1"
build_id="$2"
x86_64_b2="$3"
aarch64_b2="$4"

if [[ ! "$version" =~ ^[0-9]+(\.[0-9]+)+$ ]]; then
  echo "错误: 无效版本号 $version" >&2
  exit 2
fi

if [[ ! "$build_id" =~ ^[0-9]+$ ]]; then
  echo "错误: 无效 Build ID $build_id" >&2
  exit 2
fi

if [[ ! "$x86_64_b2" =~ ^[0-9a-f]{128}$ || \
      ! "$aarch64_b2" =~ ^[0-9a-f]{128}$ ]]; then
  echo "错误: b2sum 格式无效" >&2
  exit 2
fi

for required_line in \
  '^pkgver=' \
  '^pkgrel=' \
  '^_build=' \
  '^b2sums_aarch64=' \
  '^b2sums_x86_64='
do
  if [[ $(grep -c "$required_line" PKGBUILD) -ne 1 ]]; then
    echo "错误: PKGBUILD 中应有且仅有一行匹配 $required_line" >&2
    exit 1
  fi
done

current_version=$(sed -n 's/^pkgver=//p' PKGBUILD)
current_pkgrel=$(sed -n 's/^pkgrel=//p' PKGBUILD)
current_build=$(sed -n 's/^_build=//p' PKGBUILD)

if [[ ! "$current_version" =~ ^[0-9]+(\.[0-9]+)+$ || \
      ! "$current_pkgrel" =~ ^[0-9]+$ || \
      ! "$current_build" =~ ^[0-9]+$ ]]; then
  echo "错误: 当前 pkgver/pkgrel/_build 无效: ${current_version}-${current_pkgrel} (${current_build})" >&2
  exit 1
fi

highest_version=$(printf '%s\n%s\n' "$current_version" "$version" | sort -V | tail -n 1)
if [[ "$current_version" != "$version" && "$highest_version" != "$version" ]]; then
  echo "错误: 官网版本 $version 低于当前软件包版本 $current_version，拒绝降级" >&2
  exit 1
fi

if [[ "$current_version" == "$version" && "$current_build" == "$build_id" ]] && \
   grep -Fqx "b2sums_aarch64=('${aarch64_b2}')" PKGBUILD && \
   grep -Fqx "b2sums_x86_64=('${x86_64_b2}')" PKGBUILD; then
  echo "软件包元数据已是 ${version}-${current_pkgrel} (build ${build_id})，无需修改"
  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    echo "changed=false" >> "$GITHUB_OUTPUT"
    echo "version=$version" >> "$GITHUB_OUTPUT"
    echo "pkgrel=$current_pkgrel" >> "$GITHUB_OUTPUT"
    echo "build_id=$build_id" >> "$GITHUB_OUTPUT"
  fi
  exit 0
fi

if [[ "$current_version" == "$version" ]]; then
  pkgrel=$((current_pkgrel + 1))
else
  pkgrel=1
fi

gcs_base="https://storage.googleapis.com/antigravity-public/antigravity-hub"
aarch64_src="Antigravity-${version}-${build_id}-aarch64.tar.gz::${gcs_base}/${version}-${build_id}/linux-arm/Antigravity.tar.gz"
x86_64_src="Antigravity-${version}-${build_id}-x86_64.tar.gz::${gcs_base}/${version}-${build_id}/linux-x64/Antigravity.tar.gz"

sed -i \
  -e "s/^pkgver=.*/pkgver=${version}/" \
  -e "s/^pkgrel=.*/pkgrel=${pkgrel}/" \
  -e "s/^_build=.*/_build=${build_id}/" \
  -e "s/^b2sums_aarch64=.*/b2sums_aarch64=('${aarch64_b2}')/" \
  -e "s/^b2sums_x86_64=.*/b2sums_x86_64=('${x86_64_b2}')/" \
  PKGBUILD

sed -i \
  -e "s/^[[:space:]]*pkgver = .*/\tpkgver = ${version}/" \
  -e "s/^[[:space:]]*pkgrel = .*/\tpkgrel = ${pkgrel}/" \
  -e "s|^[[:space:]]*source_aarch64 = .*|\tsource_aarch64 = ${aarch64_src}|" \
  -e "s/^[[:space:]]*b2sums_aarch64 = .*/\tb2sums_aarch64 = ${aarch64_b2}/" \
  -e "s|^[[:space:]]*source_x86_64 = .*|\tsource_x86_64 = ${x86_64_src}|" \
  -e "s/^[[:space:]]*b2sums_x86_64 = .*/\tb2sums_x86_64 = ${x86_64_b2}/" \
  .SRCINFO

bash -n PKGBUILD

echo "软件包元数据已更新到 ${version}-${pkgrel} (build ${build_id})"
if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  echo "changed=true" >> "$GITHUB_OUTPUT"
  echo "version=$version" >> "$GITHUB_OUTPUT"
  echo "pkgrel=$pkgrel" >> "$GITHUB_OUTPUT"
  echo "build_id=$build_id" >> "$GITHUB_OUTPUT"
fi
