#!/usr/bin/env bash
set -euo pipefail

cd /home/frappe/frappe-bench

wait-for-it -t 180 erp-db:3306
wait-for-it -t 180 erp-redis-cache:6379
wait-for-it -t 180 erp-redis-queue:6379

if [[ ! -d "sites/$ERP_URL" ]]; then
  bench new-site "$ERP_URL" \
    --mariadb-user-host-login-scope='%' \
    --admin-password="$ERP_ADMIN_PASSWORD" \
    --db-root-username=root \
    --db-root-password="$DB_ROOT_PASSWORD" \
    --install-app erpnext \
    --set-default
else
  bench --site "$ERP_URL" migrate
fi

case "${ERP_ROT_RUT:-no}" in
  yes)
    if ! bench --site "$ERP_URL" list-apps | grep -Fxq basm_rot_rut; then
      bench --site "$ERP_URL" install-app basm_rot_rut
    fi ;;
  no) ;;
  *) printf 'ERP_ROT_RUT must be yes or no.\n' >&2; exit 1 ;;
esac

bench --site "$ERP_URL" enable-scheduler
