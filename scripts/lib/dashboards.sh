#!/usr/bin/env bash

dashboards_dir_for_set() {
  local dashboard_set=$1
  case "${dashboard_set}" in
    platform) printf '%s' "${PROJECT_DIR}/grafana/dashboards/platform" ;;
    tenants) printf '%s' "${PROJECT_DIR}/grafana/dashboards/tenants" ;;
    *) die "未知的仪表盘集合 ${dashboard_set}" ;;
  esac
}

dashboards_normalize() {
  local source_file=$1 output_file=$2 new_uid=$3 ds_uid="vmauth-cluster"
  jq --arg uid "${new_uid}" --arg ds_uid "${ds_uid}" '
    del(.__inputs)
    | .id = null
    | .uid = $uid
    | .version = 1
    | walk(
        if type == "object" and .type == "datasource" and (.name // "") == "ds" then
          .current = {text: $ds_uid, value: $ds_uid, selected: true}
        elif type == "object" and has("datasource") then
          .datasource |= (
            if type == "string" and (contains("$ds") or test("DS_|prometheus|victoria"; "i")) then
              {type: "prometheus", uid: $ds_uid}
            elif type == "object" and (
              ((.type // "") == "prometheus")
              or ((.uid // "") == "$ds")
              or ((.uid // "") | test("DS_|prometheus|victoria"; "i"))
              or ((.name // "") | test("prometheus|victoria"; "i"))
            ) then
              {type: "prometheus", uid: $ds_uid}
            else
              .
            end
          )
        else
          .
        end
      )
  ' "${source_file}" > "${output_file}"
}

dashboards_import() {
  local dashboard_set=$1 uid_suffix=$2 grafana_org_name=$3 overwrite=${4:-false}
  local dashboards_dir org_id dashboard_file dashboard_name tmp_file payload_file base_uid new_uid exists result count=0

  dashboards_dir="$(dashboards_dir_for_set "${dashboard_set}")"
  [ -d "${dashboards_dir}" ] || { log_warn "仪表盘目录未找到：${dashboards_dir}"; return 0; }
  org_id="$(grafana_get_org_id_by_name "${grafana_org_name}")"
  [ -n "${org_id}" ] || { log_warn "Grafana 组织 ${grafana_org_name} 未找到，跳过仪表盘导入"; return 0; }

  log_step "将 ${dashboard_set} 仪表盘导入到 ${grafana_org_name}（id=${org_id}）"
  grafana_switch_org "${org_id}"

  for dashboard_file in "${dashboards_dir}"/*.json; do
    [ -f "${dashboard_file}" ] || continue
    count=$((count + 1))
    dashboard_name="$(basename "${dashboard_file}" .json)"
    tmp_file="$(mktemp)"
    payload_file="$(mktemp)"
    base_uid="$(jq -r '.uid // empty' "${dashboard_file}")"
    [ -n "${base_uid}" ] || base_uid="${dashboard_name}"
    new_uid="${base_uid}-${uid_suffix}"
    dashboards_normalize "${dashboard_file}" "${tmp_file}" "${new_uid}"

    if [ "${overwrite}" != "true" ]; then
      exists="$(curl -sS "${GRAFANA_URL}/api/dashboards/uid/${new_uid}" -H "$(grafana_header)" | jq -r '.dashboard.uid // empty' 2>/dev/null || true)"
      if [ -n "${exists}" ]; then
        log_info "已跳过仪表盘 ${dashboard_name}，uid=${new_uid} 已存在"
        rm -f "${tmp_file}" "${payload_file}"
        continue
      fi
    fi

    jq -n --slurpfile dashboard "${tmp_file}" '{dashboard: $dashboard[0], overwrite: true, message: "Imported by scripts/manage.sh"}' > "${payload_file}"
    result="$(curl -sS -X POST "${GRAFANA_URL}/api/dashboards/db" -H "$(grafana_header)" -H "Content-Type: application/json" --data-binary "@${payload_file}")"
    if printf '%s' "${result}" | jq -e '.uid' >/dev/null 2>&1; then
      log_info "已导入仪表盘 ${dashboard_name}，uid=${new_uid}"
    else
      log_warn "仪表盘 ${dashboard_name} 导入失败：$(printf '%s' "${result}" | jq -r '.message // "未知错误"')"
    fi
    rm -f "${tmp_file}" "${payload_file}"
  done

  [ "${count}" -gt 0 ] || log_warn "在 ${dashboards_dir} 中未找到仪表盘 JSON 文件"
  grafana_switch_org 1
}
