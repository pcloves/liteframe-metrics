#!/bin/bash
# 合并 auth.d/*.yaml → auth.yaml
# 解析 ${HOST_IP}, ${KC_PORT}, ${VMADMIN_PASS} 等变量
#
# 依赖: yq (https://github.com/mikefarah/yq) v4.18+
# 用法: ./scripts/gen-auth.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$SCRIPT_DIR"

[ -f .env ] && source .env
: "${HOST_IP:?Required}" "${KC_PORT:?Required}" "${KC_REALM:=grafana}"

AUTH_D="vmauth/auth.d"
AUTH_YAML="vmauth/auth.yaml"
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

first=true
for f in $(ls "$AUTH_D"/*.yaml 2>/dev/null | sort); do
  sed -e "s/\${HOST_IP}/$HOST_IP/g" \
      -e "s/\${KC_PORT}/$KC_PORT/g" \
      -e "s/\${KC_REALM}/$KC_REALM/g" \
      -e "s/\${VMADMIN_PASS}/${VMADMIN_PASS:-vmadmin_pass}/g" \
      "$f" > "$TMP_DIR/entry.yaml"

  yq eval -o=json "$TMP_DIR/entry.yaml" > "$TMP_DIR/entry.json"

  if [ "$first" = true ]; then
    jq '{"users": [.]}' "$TMP_DIR/entry.json" > "$TMP_DIR/result.json"
    first=false
  else
    jq -s '.[0].users += [.[1]] | .[0]' \
      "$TMP_DIR/result.json" "$TMP_DIR/entry.json" > "$TMP_DIR/result2.json"
    mv "$TMP_DIR/result2.json" "$TMP_DIR/result.json"
  fi
done

if [ "$first" = false ]; then
  yq eval -P "$TMP_DIR/result.json" > "$AUTH_YAML"
  count=$(jq '.users | length' "$TMP_DIR/result.json")
else
  echo "users: []" > "$AUTH_YAML"
  count=0
fi

echo "Generated $AUTH_YAML ($count sources)"
