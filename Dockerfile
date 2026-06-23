FROM frappe/erpnext:v16

USER root

RUN apt-get update && apt-get install -y --no-install-recommends \
    git \
    && rm -rf /var/lib/apt/lists/*

USER frappe

# Eliminar el erpnext pre-instalado y copiar nuestra version
RUN rm -rf /home/frappe/frappe-bench/apps/erpnext
COPY --chown=frappe:frappe . /home/frappe/frappe-bench/apps/erpnext

WORKDIR /home/frappe/frappe-bench

# Instalar dependencias de erpnext sin tocar frappe (evita error de git repo)
RUN pip install -e apps/erpnext --no-build-isolation && \
    bench build --app erpnext && \
    bench clear-cache

COPY entrypoint.sh /home/frappe/frappe-bench/entrypoint.sh
RUN chmod +x /home/frappe/frappe-bench/entrypoint.sh

EXPOSE 8000 9000

ENTRYPOINT ["/home/frappe/frappe-bench/entrypoint.sh"]
