# SCRUM-58 · Proteger secretos y credenciales del pipeline

**Épica:** E08 · Integración y despliegue continuos (CI/CD)  
**Responsable:** Valentín Iriarte  
**Rama:** `feat/SCRUM-58-secretos-pipeline`

## 1. Situación inicial

- `ci.yml` declaraba `permissions: contents: read` a nivel workflow, pero no por job.
- Las Actions se referenciaban por tag (`actions/checkout@v4`, `actions/setup-node@v4`). Un tag se puede mover a otro commit; si la cuenta del autor se compromete, el pipeline ejecutaría código nuevo sin que nadie lo note (pasó con `tj-actions/changed-files` en marzo de 2025).
- `actions/checkout` dejaba el `GITHUB_TOKEN` guardado en `.git/config` durante todo el job.
- No había Dependabot, escaneo de secretos ni Environments.

## 2. Cambios en el repositorio

### 2.1 `.github/workflows/ci.yml`

| Cambio | Detalle |
|---|---|
| Permisos mínimos | A nivel workflow `permissions: {}` (ninguno). Cada job declara solo `contents: read`. |
| Actions fijadas por SHA | `actions/checkout@11d5960a326750d5838078e36cf38b85af677262 # v4.4.0` y `actions/setup-node@49933ea5288caeca8642d1e84afbd3f7d6820020 # v4.4.0`. El comentario indica la versión; Dependabot actualiza el SHA. |
| Token fuera del disco | `persist-credentials: false` en todos los `checkout`. |
| Nuevo job **Escaneo de secretos (gitleaks)** | Revisa todo el historial en cada PR y push. Si encuentra un secreto, el CI falla y el PR no se puede mergear. La imagen de gitleaks está fijada por **digest** (`sha256:0e99e882…`), no por tag. |
| Sin secretos en el YAML | El CI no necesita ninguno (los tests usan valores ficticios). |

### 2.2 `.github/dependabot.yml`

| Ecosistema | Directorio | Frecuencia | Agrupación |
|---|---|---|---|
| npm | `/backend` | semanal (lunes) | menores + parches en un solo PR |
| npm | `/frontend` | semanal (lunes) | `@angular/*` juntos; menores + parches juntos |
| docker | `/backend`, `/frontend` | semanal | — |
| github-actions | `/` | semanal | — |

Todos los PRs van a `develop`, con prefijo `deps(...)` y etiquetas (`dependencias`, `backend`, `frontend`, `docker`, `ci-cd`; creadas en el repo).

## 3. Configuración aplicada en GitHub (Settings)

Aplicada con `gh api` por el administrador del repo (`valentiniriar`):

| Configuración | Estado | Comando |
|---|---|---|
| Environment **`produccion`** con despliegue solo desde `main` | ✔ creado | `gh api -X PUT repos/valentiniriar/proyecto_demo_hia/environments/produccion` + branch policy `main` |
| Dependabot alerts | ✔ activado | `gh api -X PUT .../vulnerability-alerts` |
| Dependabot security updates | ✔ activado | `gh api -X PUT .../automated-security-fixes` |
| Secret scanning | ✔ activado | `PATCH .../ security_and_analysis.secret_scanning` |
| Push protection | ✔ activado: GitHub **rechaza el push** si detecta un token conocido | `security_and_analysis.secret_scanning_push_protection` |

Estado verificado:

```json
{"dependabot_security_updates":{"status":"enabled"},"secret_scanning":{"status":"enabled"},"secret_scanning_push_protection":{"status":"enabled"}}
```

## 4. Cómo cargar los secretos de despliegue (Environment `produccion`)

Los valores **no** se versionan ni se escriben en el YAML. Los carga quien administra el despliegue:

```bash
gh secret set JWT_SECRET    --env produccion   # pide el valor por consola, no queda en el historial
gh secret set DB_PASS       --env produccion
gh secret set ACCESS_TOKEN  --env produccion   # MercadoPago
gh secret set GROQ_API_KEY  --env produccion
gh secret set CLOUDFLARE_TUNNEL_TOKEN --env produccion   # SCRUM-60
# Valores no sensibles como variables:
gh variable set DB_USER --env produccion --body gymhub
```

Un workflow de despliegue (CD) los usa así; el job solo recibe los secretos si corre desde `main`:

```yaml
jobs:
  deploy:
    runs-on: ubuntu-latest
    environment: produccion          # habilita los secretos del Environment
    permissions:
      contents: read
      packages: write                # solo si publica imágenes en GHCR
    steps:
      - uses: actions/checkout@11d5960a326750d5838078e36cf38b85af677262 # v4.4.0
        with:
          persist-credentials: false
      - run: ./deploy.sh
        env:
          JWT_SECRET: ${{ secrets.JWT_SECRET }}
          DB_PASS: ${{ secrets.DB_PASS }}
```

GitHub enmascara (`***`) los secretos en los logs. Los PRs que vienen de forks no reciben secretos.

## 5. Verificación

| Prueba | Resultado |
|---|---|
| `actionlint` 1.7.7 sobre los workflows | sin errores (exit 0) |
| Paso de gitleaks ejecutado localmente con la misma imagen (por digest) y usuario no root | `37 commits scanned` · `no leaks found` |
| CI del PR de este ticket | ver checks del PR (incluye el job nuevo de secretos) |

## 6. Criterios de aceptación

| Criterio | Estado |
|---|---|
| Secretos (JWT_SECRET, DB_PASS, tokens externos) en GitHub Environments, nunca en el YAML | ✔ Environment `produccion` creado y restringido a `main`; procedimiento de carga en la sección 4; el YAML no tiene secretos. **Pendiente del equipo:** cargar los valores reales cuando exista el workflow de despliegue. |
| `permissions` mínimos declarados en cada workflow | ✔ `{}` global + `contents: read` por job |
| Actions de terceros fijadas por SHA | ✔ checkout y setup-node por SHA; imagen de gitleaks por digest |
| Dependabot habilitado para npm, Docker y GitHub Actions | ✔ `.github/dependabot.yml` + alerts y security updates activos |
