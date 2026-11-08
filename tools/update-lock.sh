#!/usr/bin/env bash
# Pins a Hysteria2 core release: reads the official hashes.txt of release VERSION (for example 2.14.0),
# rewrites releases/hysteria.lock.json and the matching constants in lib/common.sh.
# Review the resulting diff and run tests/run.sh and tests/core-config.sh before committing.
#   tools/update-lock.sh 2.14.0
set -euo pipefail
project=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
version=${1:?usage: tools/update-lock.sh VERSION (for example 2.14.0)}
[[ $version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { printf 'error: invalid version: %s\n' "$version" >&2; exit 2; }
for tool in curl jq; do command -v "$tool" > /dev/null || { printf 'error: %s is required\n' "$tool" >&2; exit 1; }; done
base=https://github.com/HyNetworks/hysteria/releases/download/app/v$version
hashes=$(curl -fsSL --retry 3 -m 60 "$base/hashes.txt") || { printf 'error: cannot download %s/hashes.txt\n' "$base" >&2; exit 1; }
sha_of() { awk -v f="build/hysteria-linux-$1" '$2 == f {print $1}' <<< "$hashes"; }
amd64=$(sha_of amd64) arm64=$(sha_of arm64)
for sum in "$amd64" "$arm64"; do
    [[ $sum =~ ^[0-9a-f]{64}$ ]] || { printf 'error: hashes.txt has no valid linux-amd64/linux-arm64 entry\n' >&2; exit 1; }
done
current=$(jq -r .version "$project/releases/hysteria.lock.json")
[[ $(printf '%s\n%s\n' "${current#v}" "$version" | sort -V | tail -n 1) == "$version" ]] || { printf 'error: v%s is older than the pin %s\n' "$version" "$current" >&2; exit 1; }
jq -n --arg v "v$version" --arg base "$base" --arg a "$amd64" --arg r "$arm64" '{
    schemaVersion: 1, version: $v,
    assets: {
        amd64: {name: "hysteria-linux-amd64", url: ($base + "/hysteria-linux-amd64"), sha256: $a},
        arm64: {name: "hysteria-linux-arm64", url: ($base + "/hysteria-linux-arm64"), sha256: $r}
    }}' > "$project/releases/hysteria.lock.json"
sed -i -e "s/^HVK_CORE_VERSION=.*/HVK_CORE_VERSION=$version/" \
    -e "s/^HVK_SHA256_AMD64=.*/HVK_SHA256_AMD64=$amd64/" \
    -e "s/^HVK_SHA256_ARM64=.*/HVK_SHA256_ARM64=$arm64/" "$project/lib/common.sh"
printf 'pinned Hysteria2 v%s\n' "$version"
