# Cómo trabajamos en GymHub

Guía de flujo de trabajo del equipo para la Práctica Integradora Final. Todo cambio al código, la infraestructura o la documentación pasa por este proceso.

## Tablero

- Jira: proyecto **GymHub team** (clave `SCRUM`) en `gymhubb.atlassian.net`.
- Cada épica `SCRUM-5` … `SCRUM-19` corresponde a un punto del enunciado (E01 … E15).
- Al empezar una tarea, moverla a **En curso**; al abrir el PR, a **En revisión**; al mergear, a **Finalizado**.

## Ramas

| Rama | Para qué | Se crea desde | Se integra en |
|---|---|---|---|
| `main` | Versión estable, la que se despliega | — | — |
| `develop` | Integración del trabajo del sprint | `main` | `main` (PR de release) |
| `feature/SCRUM-XX-descripcion` | Funcionalidades y tareas técnicas | `develop` | `develop` |
| `fix/SCRUM-XX-descripcion` | Correcciones | `develop` (o `main` si es urgente) | `develop` (y `main` si es urgente) |

Reglas:

- Nombres en minúsculas con guiones: `feature/SCRUM-35-dataset-6m`, `fix/SCRUM-50-url-api`.
- Nadie hace push directo a `main` ni a `develop`: todo entra por Pull Request.
- Una rama por ticket. Si un ticket es muy grande, se divide en Jira antes que en Git.
- Antes de abrir el PR, actualizar la rama con `develop` (`git pull --rebase origin develop`) y resolver conflictos localmente.

## Commits

Formato:

```
SCRUM-XX: descripción en imperativo y en minúsculas

Detalle opcional: qué cambia y por qué.
```

Ejemplos:

```
SCRUM-33: agregar red interna y healthcheck al compose de la base
SCRUM-50: usar environment.apiUrl en los servicios del frontend
```

La clave `SCRUM-XX` vincula automáticamente el commit con el ticket en la pestaña **Desarrollo** de Jira (requiere la app *GitHub for Jira* instalada en el sitio).

## Pull Requests

1. Abrir el PR hacia `develop` con la plantilla (se carga sola).
2. Título: `SCRUM-XX: descripción`.
3. Pedir revisión a **al menos un integrante** que no haya escrito el código.
4. El CI tiene que estar en verde.
5. Quien revisa aprueba o pide cambios con comentarios concretos; las discusiones se resuelven en el PR, no por chat, para que quede registro.
6. Merge con **Squash and merge** y borrar la rama.

Release: al cierre de cada sprint se abre un PR `develop → main` con el resumen del sprint.

## Definition of Done

Una tarea está terminada cuando se cumple todo esto:

- [ ] Cumple los criterios de aceptación del ticket.
- [ ] El código está en una rama `feature/` o `fix/` y entró por PR revisado por al menos 1 integrante.
- [ ] El pipeline de CI pasó.
- [ ] Hay evidencia (captura, log, salida de comando o test) adjunta al ticket o al PR.
- [ ] La documentación afectada está actualizada en `docs/` y subida a Nextcloud.
- [ ] No se subieron secretos, `.env`, dumps con datos ni credenciales.
- [ ] El ticket está en **Finalizado** en Jira.

## Secretos

- Nunca se versionan `.env`, claves, tokens ni backups de la base. Solo `.env.example` con valores de ejemplo.
- Los secretos del pipeline van en *GitHub → Settings → Environments*.
- Si un secreto se sube por error: avisar al equipo, **rotarlo de inmediato** y recién después limpiar el historial. Borrar el commit no alcanza.

## Protección de ramas (configuración del repositorio)

La debe aplicar quien administra el repositorio (`valentiniriar`), en *Settings → Rules → Rulesets → New branch ruleset*:

- **Target:** `main` y `develop`.
- **Restrict deletions** y **Block force pushes**.
- **Require a pull request before merging**, con 1 aprobación y *Dismiss stale approvals*.
- **Require status checks to pass:** los jobs del workflow `CI` (una vez que exista en `develop`).
- **Require conversation resolution before merging**.

Equivalente por línea de comandos (requiere permisos de administrador):

```bash
gh api -X PUT repos/valentiniriar/proyecto_demo_hia/branches/main/protection \
  -H "Accept: application/vnd.github+json" --input - <<'EOF'
{
  "required_status_checks": { "strict": true, "contexts": [] },
  "enforce_admins": true,
  "required_pull_request_reviews": { "required_approving_review_count": 1, "dismiss_stale_reviews": true },
  "restrictions": null,
  "allow_force_pushes": false,
  "allow_deletions": false,
  "required_conversation_resolution": true
}
EOF
```

Repetir cambiando `main` por `develop`. Cuando el CI esté en `develop`, agregar los nombres de sus jobs en `contexts`.
