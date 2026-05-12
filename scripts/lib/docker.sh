#!/usr/bin/env bash

compose_up() {
  log_step "启动 Docker 服务并等待健康检查通过"
  docker compose up -d --wait --wait-timeout 300
  log_ok "Docker 服务已启动且健康"
}
