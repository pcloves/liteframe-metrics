#!/usr/bin/env bash

compose_up() {
  log_step "启动 Docker 服务"
  docker compose up -d
  log_ok "Docker 服务已启动"
}

wait_for_keycloak() {
  log_step "等待 Keycloak 就绪"
  wait_for_http_200 Keycloak "${KC_URL}/realms/master" 30 3 || die "Keycloak 未就绪"
}

wait_for_grafana() {
  log_step "等待 Grafana 就绪"
  wait_for_http_200 Grafana "${GRAFANA_URL}/api/orgs" 60 2 -H "$(grafana_header)" || die "Grafana 未就绪；请检查 GF_ADMIN_PASS 和容器日志"
}
