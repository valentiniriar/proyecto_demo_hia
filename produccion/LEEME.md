# Carpeta `produccion/`

Secretos y estado del **servidor de producción**. Todo lo que hay acá, salvo este archivo, está en `.gitignore`: **nunca se sube al repositorio**. Cada servidor tiene su propia copia.

| Archivo | Qué contiene | Quién lo usa |
|---|---|---|
| `.env.prod` | `DB_NAME`, `DB_USER`, `DB_PASS`, `POSTGRES_REPLICA_USER`, `POSTGRES_REPLICA_PASSWORD`, `JWT_SECRET`, configuración de backups y `CLOUDFLARE_TUNNEL_TOKEN` (opcional) | `scripts/deploy.sh` y el CD |
| `credenciales-produccion.txt` | Contraseñas de los usuarios de la app en producción (`admin`, `entrenador`; `socio` usa la de demostración) | Personas |
| `version-desplegada.txt` | SHA de la versión que está en producción | `scripts/deploy.sh` (rollback automático) |
| `historial-despliegues.log` | Una línea por despliegue: fecha, SHA y resultado (`OK`, `FALLÓ`, `ROLLBACK OK`) | `scripts/deploy.sh --estado` |
| `CREDENCIALES.txt` | **Todas** las credenciales juntas: app, base, Grafana, Mantis, n8n y túnel. Se genera con `bash scripts/infra.sh credenciales` | Personas |

Las credenciales de las herramientas viven además junto a su compose, también ignoradas por Git: `infra/monitoring/.env`, `infra/mantis/.env`, `infra/mantis/credenciales.local.json` e `infra/n8n/.env`. `CREDENCIALES.txt` las reúne en un solo lugar.

## Crear `.env.prod` en un servidor nuevo

```ini
DB_NAME=gymhub
DB_USER=gymhub
DB_PASS=<aleatoria>
POSTGRES_REPLICA_USER=replicator
POSTGRES_REPLICA_PASSWORD=<aleatoria>
JWT_SECRET=<aleatoria, 48+ bytes>
BACKUP_CRON_SCHEDULE=0 3 * * *
BACKUP_RETENTION_DAYS=7
RUN_BACKUP_ON_STARTUP=true
CLOUDFLARE_TUNNEL_TOKEN=
```

Valores aleatorios: `node -e "console.log(require('crypto').randomBytes(32).toString('hex'))"`.

## El runner del CD

El job de despliegue corre en la copia del repo del runner (`C:\actions-runner\_work\...`), no en esta carpeta. Para que encuentre este `.env.prod`, crear `C:\actions-runner\gymhub-env.cmd` (no versionado):

```bat
@echo off
set "GYMHUB_ENV_FILE=C:/ruta/al/proyecto/produccion/.env.prod"
```

`infra/runner/iniciar-runner.cmd` lo carga al arrancar el runner. La versión desplegada y el historial se guardan en la misma carpeta que el `.env.prod`.

## Seguridad

- No copiar estos archivos a Jira, Nextcloud público, chats ni capturas.
- Si se filtra un valor, **rotarlo** (cambiarlo en `.env.prod` o en la herramienta, redesplegar o reiniciar) y regenerar `CREDENCIALES.txt`.
- Para respaldarlos, hacerlo en un medio cifrado.
