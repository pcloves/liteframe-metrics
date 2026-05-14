#!/usr/bin/env bash

prepare_keycloak_data_dir() {
  local data_dir="keycloak/data"
  local keycloak_uid="${KEYCLOAK_CONTAINER_UID:-1000}"
  local keycloak_gid="${KEYCLOAK_CONTAINER_GID:-1000}"

  log_step "检查 Keycloak 数据目录权限"
  mkdir -p "${data_dir}"

  if [ "$(id -u)" -eq 0 ]; then
    chown -R "${keycloak_uid}:${keycloak_gid}" "${data_dir}"
    chmod -R u+rwX "${data_dir}"
    log_ok "Keycloak 数据目录权限已设置为 ${keycloak_uid}:${keycloak_gid}"
    return
  fi

  if find "${data_dir}" ! -user "${keycloak_uid}" -print -quit | grep -q .; then
    die "Keycloak 官方镜像以 UID ${keycloak_uid} 写入 keycloak/data。请执行：sudo chown -R ${keycloak_uid}:${keycloak_gid} keycloak/data && sudo chmod -R u+rwX keycloak/data"
  fi
  if find "${data_dir}" ! -perm -u+w -print -quit | grep -q .; then
    die "keycloak/data 缺少属主写权限。请执行：sudo chmod -R u+rwX keycloak/data"
  fi

  log_ok "Keycloak 数据目录权限检查通过"
}

compose_up() {
  log_step "启动 Docker 服务并等待健康检查通过"
  docker compose up -d --wait --wait-timeout 300
  log_ok "Docker 服务已启动且健康"
}
