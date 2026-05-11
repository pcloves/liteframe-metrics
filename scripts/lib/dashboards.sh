#!/usr/bin/env bash

dashboards_import() {
  local org_name=$1 grafana_org_name=$2 overwrite=${3:-false}
  local dashboards_dir="${PROJECT_DIR}/grafana/dashboards/default"
  local org_id dashboard_file dashboard_name tmp_file base_uid new_uid exists payload result count=0

  [ -d "${dashboards_dir}" ] || { log_warn "Dashboard directory not found: ${dashboards_dir}"; return 0; }
  org_id="$(grafana_get_org_id_by_name "${grafana_org_name}")"
  [ -n "${org_id}" ] || { log_warn "Grafana org ${grafana_org_name} not found; skipping dashboard import"; return 0; }

  log_step "Import dashboards into ${grafana_org_name} (id=${org_id})"
  grafana_switch_org "${org_id}"

  for dashboard_file in "${dashboards_dir}"/*.json; do
    [ -f "${dashboard_file}" ] || continue
    count=$((count + 1))
    dashboard_name="$(basename "${dashboard_file}" .json)"
    tmp_file="$(mktemp)"
    cp "${dashboard_file}" "${tmp_file}"

    base_uid="$(jq -r '.uid // empty' "${tmp_file}")"
    [ -n "${base_uid}" ] || base_uid="${dashboard_name}"
    new_uid="${base_uid}-${org_name}"
    jq --arg uid "${new_uid}" '.uid = $uid | .version = 1' "${tmp_file}" > "${tmp_file}.next"
    mv "${tmp_file}.next" "${tmp_file}"

    if [ "${overwrite}" != "true" ]; then
      exists="$(curl -sS "${GRAFANA_URL}/api/dashboards/uid/${new_uid}" -H "$(grafana_header)" | jq -r '.dashboard.uid // empty' 2>/dev/null || true)"
      if [ -n "${exists}" ]; then
        log_info "Skipped dashboard ${dashboard_name}; uid=${new_uid} already exists"
        rm -f "${tmp_file}"
        continue
      fi
    fi

    payload="$(jq -n --slurpfile dashboard "${tmp_file}" '{dashboard: $dashboard[0], overwrite: true, message: "Imported by scripts/manage.sh"}')"
    result="$(curl -sS -X POST "${GRAFANA_URL}/api/dashboards/db" -H "$(grafana_header)" -H "Content-Type: application/json" -d "${payload}")"
    if printf '%s' "${result}" | jq -e '.uid' >/dev/null 2>&1; then
      log_info "Imported dashboard ${dashboard_name}; uid=${new_uid}"
    else
      log_warn "Dashboard ${dashboard_name} import failed: $(printf '%s' "${result}" | jq -r '.message // "unknown"')"
    fi
    rm -f "${tmp_file}"
  done

  [ "${count}" -gt 0 ] || log_warn "No dashboard JSON files found in ${dashboards_dir}"
  grafana_switch_org 1
}
