FROM frappe/erpnext:develop

USER root

RUN apt-get update && apt-get install -y --no-install-recommends \
    git \
    && rm -rf /var/lib/apt/lists/*

USER frappe

# Eliminar el erpnext pre-instalado y copiar nuestra version
RUN rm -rf /home/frappe/frappe-bench/apps/erpnext
COPY --chown=frappe:frappe . /home/frappe/frappe-bench/apps/erpnext

WORKDIR /home/frappe/frappe-bench

# Install ERPNext Python and frontend dependencies before asset build.
# `yarn install` is required because the copied app includes package.json
# dependencies (for example `onscan.js`) that are not present in the base image.
# `--no-build-isolation` stays removed so pip can install flit_core per PEP 517.
# Build-time: install Python deps, build frontend assets, and build
# Frappe/ERPNext JS/CSS bundles.  Do NOT run bench clear-cache here —
# no site exists yet (sites are created at container start by entrypoint.sh).
RUN cd apps/erpnext && yarn install --frozen-lockfile && cd /home/frappe/frappe-bench && \
    pip install -e apps/erpnext && \
    bench build --app erpnext

COPY --chown=frappe:frappe --chmod=755 entrypoint.sh /home/frappe/frappe-bench/entrypoint.sh

EXPOSE 8000 9000

ENTRYPOINT ["/home/frappe/frappe-bench/entrypoint.sh"]
