FROM frappe/erpnext-worker:v16

USER root

RUN apt-get update && apt-get install -y --no-install-recommends \
    git \
    curl \
    && rm -rf /var/lib/apt/lists/*

USER frappe

COPY --chown=frappe:frappe . /home/frappe/frappe-bench/apps/erpnext

WORKDIR /home/frappe/frappe-bench

RUN bench setup requirements && \
    bench build --app erpnext && \
    bench clear-cache

COPY entrypoint.sh /home/frappe/frappe-bench/entrypoint.sh
RUN chmod +x /home/frappe/frappe-bench/entrypoint.sh

EXPOSE 8000 9000

ENTRYPOINT ["/home/frappe/frappe-bench/entrypoint.sh"]
