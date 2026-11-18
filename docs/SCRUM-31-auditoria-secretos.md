# SCRUM-31 · Auditoría de secretos en el repositorio y limpieza de `test_mp.js`

**Épica:** E03 · Control de versiones y calidad del código  
**Responsable:** Valentín Iriarte  
**Rama:** `fix/SCRUM-31-auditoria-secretos`  
**Incidencia Mantis relacionada:** BUG-002 (ver `docs/SCRUM-71-incidencias-mantis.md`)

## 1. Objetivo

Verificar que el repositorio público `valentiniriar/proyecto_demo_hia` no contenga secretos (tokens, contraseñas, claves privadas) ni datos personales reales, en ninguna rama ni en el historial, y corregir el script suelto `backend/test_mp.js`.

## 2. Escaneo del historial con gitleaks

Herramienta: [gitleaks](https://github.com/gitleaks/gitleaks) v8.21.2 (imagen Docker oficial), con su set de reglas por defecto (≈160 detectores: AWS, GitHub, Google, Stripe/MercadoPago, JWT, claves privadas, contraseñas genéricas, etc.).

### 2.1 Historial completo (todas las ramas, incluidas las remotas)

```bash
docker run --rm -v "$(pwd):/repo" zricethezav/gitleaks:v8.21.2 \
  git /repo --log-opts="--all" --redact --report-format json --report-path /repo/.gitleaks-report.json
```

Salida:

```
INF 34 commits scanned.
INF scan completed in 2.19s
INF no leaks found
```

Reporte JSON: `[]` (sin hallazgos).

> 34 = total de commits que no son de merge en todas las ramas (`git rev-list --all --no-merges --count` → 34). Los commits de merge no agregan contenido propio, así que quedan cubiertos.

### 2.2 Árbol de trabajo actual (archivos sin commitear incluidos)

```bash
docker run --rm -v "$(pwd):/repo" zricethezav/gitleaks:v8.21.2 dir /repo --redact
```

```
INF scan completed in 1m29.5s
INF no leaks found
```

### 2.3 Verificaciones manuales complementarias

| Verificación | Comando | Resultado |
|---|---|---|
| Archivos sensibles alguna vez agregados (`.env`, `.pem`, `.key`, dumps) | `git log --all --diff-filter=A --name-only` filtrado | Ninguno. Solo aparecen `database/01_schema.sql` y `02_seed.sql` (esquema y seed demo) y scripts de backup (código, no backups). |
| Asignaciones de `DB_PASS`, `JWT_SECRET`, `ACCESS_TOKEN`, `*_API_KEY`, `PASSWORD` con valor | `git log --all -p` + grep | Solo valores ficticios o de desarrollo: `CLAVE_FICTICIA_SOLO_TEST`, `test_jwt_secret_key_…` (tests), `CLAVE_SOLO_EN_ARCHIVO_PRIVADO` (placeholder), ejemplo de README. |
| Certificados `localhost*.pem` del repo original del frontend | — | Nunca se subieron a este repositorio (se excluyeron al unificar). |
| `client_id` de Google OAuth en `login.component.ts` / `register.component.ts` | revisión manual | Es un identificador **público** por diseño (va en el navegador). No es secreto. |

## 3. Seed solo con usuarios demo ficticios

`database/02_seed.sql` contiene únicamente:

- 3 usuarios ficticios: `admin@demo.com`, `entrenador@demo.com`, `socio@demo.com`, con DNI `10000001`–`10000003` y contraseña demo hasheada con bcrypt.
- Ejercicios, una rutina, una suscripción, cuotas y un pago con transacción `DEMO-0001`.

No hay nombres, DNIs, emails ni pagos de personas reales. ✔

## 4. Limpieza de `test_mp.js`

**Hallazgo:** `backend/test_mp.js` cargaba el `.env` desde una ruta absoluta de otra máquina (`d:\Facultad\...\proybackendgrupoG06\.env`) y estaba suelto en la raíz del backend.

**Corrección:**

- Se movió a `backend/scripts/test-mp.js` (`git mv`, se conserva el historial).
- Carga `backend/.env` con una ruta relativa al script (`path.join(__dirname, '..', '.env')`).
- Si falta `ACCESS_TOKEN` termina con un mensaje claro y código de salida 1, sin llamar a la API.
- Las `back_urls` usan `FRONTEND_URL` (por defecto `http://localhost:4200`) en vez de estar fijas.
- Nuevo script npm: `npm run test:mp`.
- `backend/.dockerignore` excluye toda la carpeta `scripts/` de la imagen de producción.

## 5. `.gitignore` reforzado

Se agregaron a la raíz:

| Patrón | Para qué |
|---|---|
| `*.p12`, `*.pfx`, `credentials*.json`, `cloudflared/*.json` | Certificados y credenciales (incluidas las del túnel de Cloudflare, SCRUM-60). |
| `*.sql` + excepción `!database/*.sql` | Cualquier dump `.sql` queda ignorado; solo se versionan el esquema y el seed demo. |
| `*.sql.gz`, `*.dump`, `*.backup`, `*.bak`, `backups/`, `dumps/` | Backups de `pg_dump` / `pg_basebackup` y copias locales. |

Ya estaban cubiertos: `.env`, `.env.*` (salvo `.env.example`), `*.pem`, `*.key`, `node_modules/`.

## 6. Observaciones (no son secretos filtrados)

- Los compose de **desarrollo** traen valores por defecto débiles (`demo_hia_pass`, `admin1234` de pgAdmin, `dev_jwt_secret_key_…`). Son aceptables solo en local; `compose.prod.yaml` toma todo de variables de entorno sin defaults. Se recomienda mantenerlo así.
- Si algún día se sube un secreto por error: **rotarlo primero**, después limpiar el historial (ver `CONTRIBUTING.md` → Secretos).

## 7. Criterios de aceptación

| Criterio | Estado |
|---|---|
| Escaneo del historial con gitleaks sin hallazgos, salida adjunta | ✔ Sección 2 |
| `test_mp.js` eliminado o movido a `scripts/` sin rutas absolutas | ✔ Sección 4 |
| `.gitignore` cubre `.env`, dumps `.sql` con datos y backups | ✔ Sección 5 |
| Seed solo con usuarios demo ficticios | ✔ Sección 3 |
