ARG BASE_IMAGE=frappe/erpnext:v16
FROM ${BASE_IMAGE}

USER root
COPY --chown=frappe:frappe . /home/frappe/frappe-bench/apps/basm_rot_rut
USER frappe
RUN ./env/bin/pip install --no-deps -e apps/basm_rot_rut \
    && bench build --app basm_rot_rut
