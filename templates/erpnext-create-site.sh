#!/usr/bin/env bash
set -euo pipefail

cd /home/frappe/frappe-bench

if [[ ! -d "sites/$ERP_URL" ]]; then
  wait-for-it -t 180 erp-db:3306
  wait-for-it -t 180 erp-redis-cache:6379
  wait-for-it -t 180 erp-redis-queue:6379

  bench new-site "$ERP_URL" \
    --mariadb-user-host-login-scope='%' \
    --admin-password="$ERP_ADMIN_PASSWORD" \
    --db-root-username=root \
    --db-root-password="$DB_ROOT_PASSWORD" \
    --install-app erpnext \
    --set-default
fi

bench --site "$ERP_URL" enable-scheduler