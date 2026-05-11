#!/usr/bin/env bash

compose_up() {
  log_step "Start Docker services"
  docker compose up -d
  log_ok "Docker services started"
}

wait_for_keycloak() {
  log_step "Wait for Keycloak"
  wait_for_http_200 Keycloak "${KC_URL}/realms/master" 30 3 || die "Keycloak not ready"
}

wait_for_grafana() {
  log_step "Wait for Grafana"
  wait_for_http_200 Grafana "${GRAFANA_URL}/api/orgs" 60 2 -H "$(grafana_header)" || die "Grafana not ready; check GF_ADMIN_PASS and container logs"
}
