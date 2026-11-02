case $- in
*i*)
  server_ip="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i = 1; i <= NF; i++) if ($i == "src") {print $(i + 1); exit}}')"
  if [ -z "$server_ip" ]; then
    server_ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
  fi
  [ -n "$server_ip" ] || server_ip="unavailable"

  if ! command -v docker >/dev/null 2>&1; then
    stack_status="Docker command not installed"
  elif container_names="$(docker ps --filter name=basm --format '{{.Names}}' 2>/dev/null)"; then
    running_containers="$(printf '%s\n' "$container_names" | awk 'NF {count++} END {print count + 0}')"
    stack_status="$running_containers running container(s)"
  else
    stack_status="Status unavailable to this login; check with sudo"
  fi

  printf '\n=== BASM ===\nHost: %s  |  IPv4: %s\nStack: %s\nTip: sudo basm status\n\n' \
    "$(hostname)" "$server_ip" "$stack_status"
  ;;
esac
