# shellcheck shell=sh
case $- in
*i*)
  server_ip="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i = 1; i <= NF; i++) if ($i == "src") {print $(i + 1); exit}}')"
  if [ -z "$server_ip" ]; then
    server_ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
  fi
  [ -n "$server_ip" ] || server_ip="unavailable"

  docker_service="$(systemctl is-active docker.service 2>/dev/null || true)"
  [ -n "$docker_service" ] || docker_service="unavailable"

  if ! command -v docker >/dev/null 2>&1; then
    stack_status="Docker command not installed"
  elif container_names="$(docker ps --filter name=basm --format '{{.Names}}' 2>/dev/null)"; then
    running_containers="$(printf '%s\n' "$container_names" | awk 'NF {count++} END {print count + 0}')"
    stack_status="$running_containers running container(s)"
  else
    stack_status="Status unavailable to this login; check with sudo"
  fi

  printf '\n=== BASM ===\nHost: %s  |  IPv4: %s\nDocker service: %s\nStack: %s\n' \
    "$(hostname)" "$server_ip" "$docker_service" "$stack_status"
  if [ -r "${BASM_LOGIN_URL_FILE:-/etc/profile.d/basm-login-url}" ] &&
    IFS= read -r basm_login_url < "${BASM_LOGIN_URL_FILE:-/etc/profile.d/basm-login-url}" &&
    [ -n "$basm_login_url" ]; then
    printf 'Start page: %s\n' "$basm_login_url"
  fi
  printf 'Details and URLs: sudo basm status\n\n'
  ;;
esac
