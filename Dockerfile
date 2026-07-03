# Pinned to deterministic digest for reproducible builds and safe rollbacks.
# The :develop tag is kept as a human-readable label; the @sha256 digest
# is the actual immutable reference (linux/amd64).
FROM frappe/erpnext:develop@sha256:14cc8841beadf372b3b618eae1b062ce6263fead1124a63518056e64a280378e

USER root

RUN apt-get update && apt-get install -y --no-install-recommends \
    git curl \
    && rm -rf /var/lib/apt/lists/*

USER frappe

# Remove the pre-installed erpnext and copy our version
RUN rm -rf /home/frappe/frappe-bench/apps/erpnext
COPY --chown=frappe:frappe . /home/frappe/frappe-bench/apps/erpnext

WORKDIR /home/frappe/frappe-bench

# --- Frappe bundle preservation ---
# bench build --app erpnext regenerates assets.json with ONLY erpnext bundles,
# losing ~40 Frappe entries (website, login, desk, etc).  Save them first.
RUN python3 <<'PYEOF'
import json
with open('/home/frappe/frappe-bench/assets/assets.json') as f:
    data = json.load(f)
frappe_entries = {k: v for k, v in data.items() if '/frappe/' in v}
with open('/tmp/frappe_assets.json', 'w') as f:
    json.dump(frappe_entries, f)
print(f"Saved {len(frappe_entries)} Frappe bundle entries")
PYEOF

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
    bench build --app erpnext && \
    python3 <<'PYEOF'
import json
# Read bench build output (new erpnext hashes)
with open('/home/frappe/frappe-bench/sites/assets/assets.json') as f:
    data = json.load(f)
# Add saved Frappe entries from base image
with open('/tmp/frappe_assets.json') as f:
    frappe_entries = json.load(f)
data.update(frappe_entries)
with open('/home/frappe/frappe-bench/sites/assets/assets.json', 'w') as f:
    json.dump(data, f, indent=4)
print(f"Merged assets.json: {len(data)} total entries")
PYEOF

# Backup pre-built assets to a non-volume path so configurator can sync them
RUN cp -r /home/frappe/frappe-bench/sites/assets /home/frappe/assets-backup

COPY --chown=frappe:frappe --chmod=755 entrypoint.sh /home/frappe/frappe-bench/entrypoint.sh

EXPOSE 8000 9000

ENTRYPOINT ["/home/frappe/frappe-bench/entrypoint.sh"]
