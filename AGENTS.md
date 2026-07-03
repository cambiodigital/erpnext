# AGENTS.md — ERPNext Custom Deployment

> Reglas, hitos y buenas prácticas. Este archivo crece con el proyecto.

---

## Reglas

### Archivos protegidos — NO modificar sin aprobación explícita
- `Dockerfile` — build de imagen Docker, lógica de preservación de assets Frappe
- `docker-compose.yml` — topología de servicios, healthchecks, labels Traefik
- `entrypoint.sh` — entrypoint multi-rol (configurator, web, socketio, workers)
- `deploy/nginx.conf.template` — template nginx con resolver DNS dinámico

### Archivos de configuración — NO commitear secrets
- `.env` — contiene contraseñas. Está en `.gitignore` (verificar). Solo existe en el servidor.

### Buenas prácticas generales
- Nunca modificar assets compilados (`sites/assets/`, `apps/*/public/dist/`) manualmente. Se generan en el build.
- No correr `bench build` en runtime — rompe la sincronización assets.json ↔ archivos.
- Los assets se pre-compilan en el `Dockerfile` y se respaldan en `/home/frappe/assets-backup`.
- El `entrypoint.sh` sincroniza desde el backup al volumen, NUNCA ejecuta bench build.
- Los volúmenes Docker (`sites_data`, `db_data`, `redis_*_data`) contienen datos de producción. Nunca borrarlos sin respaldo.
- Siempre probar cambios en un entorno staging antes de deploy a producción.

### Regla de persistencia de configuración runtime
- **Toda configuración de runtime que afecte integraciones externas DEBE estar en `entrypoint.sh`**, no aplicarse manualmente sobre el volumen.
- Esto incluye: `host_name` (OAuth callbacks), claves de API de terceros configuradas vía `bench set-config`, URLs de webhook, y cualquier setting que Frappe/ERPNext use para construir URLs públicas.
- **El volumen Docker es efímero desde la perspectiva del código** — un redeploy, merge de fork, o recreación del sitio puede regenerarlo. Solo lo que está en `entrypoint.sh` (o en el `Dockerfile`) sobrevive.
- **Al mergear el fork upstream**, revisar `entrypoint.sh` y `docker-compose.yml` contra nuestros cambios custom y preservar los nuestros (ver sección "Sincronizar fork con upstream").
- Si una configuración se descubre como necesaria en producción pero falta en `entrypoint.sh`, **agregarla inmediatamente al entrypoint** y documentarla aquí.

### Convenciones de commits
- Usar conventional commits: `fix:`, `feat:`, `chore:`, `docs:`
- Commits atómicos — un cambio lógico por commit
- No commitear secrets, tokens, ni contraseñas

---

## Hitos

| Fecha | Hito | Descripción |
|-------|------|-------------|
| 2026-07-02 | Fix 502 + CSS + SocketIO | 3 bugs corregidos: DNS cache nginx, assets.json desync, socketio healthcheck |
| 2026-07-02 | Backup de assets | `Dockerfile` respalda assets en `/home/frappe/assets-backup` (fuera del volumen) |
| 2026-07-02 | Preservación Frappe entries | `bench build --app erpnext` borraba entries de Frappe en `assets.json`. Se guardan y mergean post-build |
| 2026-07-02 | Push a GitHub | 4 commits en `develop`. Dokploy hace deploy automático |

---

## Arquitectura

### Estructura de archivos clave
```
/
├── Dockerfile              # Imagen Docker (protegido)
├── docker-compose.yml      # Servicios (protegido)
├── entrypoint.sh           # Entrypoint multi-rol (protegido)
├── deploy/
│   └── nginx.conf.template # Template nginx (protegido)
├── .env                    # Variables de entorno (server-only, no commit)
├── erpnext/                # Código ERPNext custom
└── banking/                # Módulo banking
```

### Servicios Docker
| Servicio | Rol | Puerto |
|----------|-----|--------|
| nginx | Reverse proxy + static assets | 80 (interno) |
| web | Gunicorn WSGI | 8000 (interno) |
| socketio | Node.js real-time | 9000 (interno) |
| worker-* | Background tasks (default/short/long) | — |
| scheduler | Tareas programadas | — |
| configurator | One-shot bootstrap/migrate | — |
| db | MariaDB 10.6 | 3306 (interno) |
| redis-cache | Redis cache | 6379 (interno) |
| redis-queue | Redis queue + socketio pub/sub | 6379 (interno) |

### Volumen vs Imagen
- `sites_data` → `/home/frappe/frappe-bench/sites` (datos de sitio, assets.json, DB sqlite)
- `db_data` → `/var/lib/mysql` (MariaDB)
- `redis_cache_data`, `redis_queue_data` → Redis persistence
- Los assets compilados viven en la IMAGEN (`apps/*/public/dist/`), NO en el volumen
- El backup de assets en `/home/frappe/assets-backup` está en la IMAGEN (no se pierde con redeploy)

### Flujo de assets
1. Docker build → bench build compila todo → se guarda backup en `/home/frappe/assets-backup`
2. Configurator (runtime) → `cp -r /home/frappe/assets-backup/. sites/assets/` al volumen
3. Nginx → try_files desde volumen, fallback a @backend (web:8000) vía symlinks
4. Web → sirve assets desde `apps/*/public/dist/` a través de symlinks en `sites/assets/`

---

## Sincronizar fork con upstream

```bash
# 1. Asegurate de estar en develop limpio
git checkout develop
git status  # debe estar limpio

# 2. Agregá upstream (solo la primera vez)
git remote add upstream https://github.com/frappe/erpnext.git

# 3. Fetch upstream
git fetch upstream

# 4. Merge upstream (ESPERÁ CONFLICTOS en archivos protegidos)
git merge upstream/develop

# 5. Resolvé conflictos manualmente archivo por archivo:
#    - Dockerfile: mantené NUESTRAS secciones (backup, merge)
#    - docker-compose.yml: mantené NUESTROS healthchecks y labels
#    - entrypoint.sh: mantené NUESTRO sync desde backup
#    - deploy/nginx.conf.template: mantené NUESTRO resolver dinámico Y X-Frappe-Site-Name en socketio

# 6. Commit del merge
git add .
git commit -m "chore: merge upstream/develop"

# 7. Push
git push origin develop

# 8. Dokploy hará deploy automático
```

---

## Troubleshooting

### 502 Bad Gateway
- Causa: nginx no resuelve `web` (DNS cache). Verificar `resolver 127.0.0.11` en nginx.conf.
- Fix: `docker compose up -d --force-recreate nginx` o `docker exec ... nginx -s reload`

### CSS sin estilos (MIME type text/html)
- Causa: `assets.json` con hashes incorrectos. Verificar en volumen: `docker run --rm -v erpnext-erp-rhpcwc_sites_data:/sites alpine cat /sites/assets/assets.json`
- Fix: redeploy limpio (el configurator sincroniza desde backup)

### SocketIO unhealthy
- Causa: healthcheck sin `EIO=4`. Verificar docker-compose.yml.
- Fix: ya está corregido en el código.

### Socket.io "Invalid origin" en consola del navegador
- Causa: el middleware `authenticate.js` de Frappe compara `Host` vs `Origin`, y detrás de Traefik los headers pueden desincronizarse en el upgrade a WebSocket.
- Fix: el template `deploy/nginx.conf.template` DEBE incluir `proxy_set_header X-Frappe-Site-Name $host;` en el bloque `location /socket.io/`. Esto le dice explícitamente al servidor socketio qué sitio usar, saltando la validación frágil de origin.
- Al mergear upstream: verificar que esta línea esté presente en el template, reponerla si el merge la borra.

### Error "Permission denied" en sites/assets/
- Causa: directorio creado como root en vez de frappe (UID 1000)
- Fix: `docker run --rm -v erpnext-erp-rhpcwc_sites_data:/sites alpine chown -R 1000:1000 /sites/assets`
