# Pinned to deterministic digest for reproducible builds and safe rollbacks.
# The :develop tag is kept as a human-readable label; the @sha256 digest
# is the actual immutable reference (linux/amd64).
FROM frappe/erpnext:develop@sha256:8953f05ebe8f77bbc8e8d26b3302d78d4755e510113990f3a94deaedf650e2a1

USER root

RUN apt-get update && apt-get install -y --no-install-recommends \
    git curl \
    && rm -rf /var/lib/apt/lists/*

USER frappe

# Remove the pre-installed erpnext and copy our version
RUN rm -rf /home/frappe/frappe-bench/apps/erpnext
COPY --chown=frappe:frappe . /home/frappe/frappe-bench/apps/erpnext

WORKDIR /home/frappe/frappe-bench

# Install ERPNext Python and frontend dependencies before asset build.
# `yarn install` is required because the copied app includes package.json
# dependencies (for example `onscan.js`) that are not present in the base image.
# Build-time: install Python deps, gunicorn (production WSGI), build frontend
# assets, and build Frappe/ERPNext JS/CSS bundles.  Do NOT run bench clear-cache
# here — no site exists yet (sites are created at container start by the
# configurator role in entrypoint.sh).
RUN cd apps/erpnext && yarn install --frozen-lockfile && cd /home/frappe/frappe-bench && \
    /home/frappe/frappe-bench/env/bin/pip install -e apps/erpnext && \
    /home/frappe/frappe-bench/env/bin/pip install gunicorn && \
    bench build --app erpnext

# Backup pre-built assets to a non-volume path so configurator can sync them
RUN cp -r /home/frappe/frappe-bench/sites/assets /home/frappe/assets-backup

COPY --chown=frappe:frappe --chmod=755 entrypoint.sh /home/frappe/frappe-bench/entrypoint.sh

EXPOSE 8000 9000

ENTRYPOINT ["/home/frappe/frappe-bench/entrypoint.sh"]
