# Seguimiento del proyecto (dailies, impedimentos y decisiones)

Ticket: SCRUM-27 · Épica: E02 Gestión con Scrum

Cada integrante agrega su entrada del día (o se registra al final de la daily). Formato breve: qué hice, qué voy a hacer, qué me bloquea.

## Sprints

| Sprint | Fechas | Objetivo |
|---|---|---|
| Sprint 1 – Base y datos | 07/11 – 10/11 | Diagnóstico, tablero, flujo Git, BD en Docker con pgAdmin, dataset de 6M y backups |
| Sprint 2 – BD y despliegue | 11/11 – 13/11 | Optimización SQL, replicación, app contenerizada, CI/CD y acceso desde Internet |
| Sprint 3 – Operación y entrega | 14/11 – 17/11 | Monitoreo, Mantis, Nextcloud, n8n, seguridad y documentación final |

## Dailies

### 10/11/2026

| Integrante | Hecho | Próximo | Bloqueos |
|---|---|---|---|
| Francisco Paredes | Tablero Jira (SCRUM-25), flujo Git y DoD (SCRUM-26, 28, 30), arquitectura (SCRUM-22), diagnóstico (SCRUM-23) | Dockerfile backend (SCRUM-51), CI (SCRUM-55), dependencias (SCRUM-64) | Sin permiso de escritura en el repo de GitHub (IMP-01) |
| Enzo Villagrán | | | |
| Valentín Lozano | | | |
| valentin iriarte | | | |
| Tizi Galloo | | | |

## Impedimentos

| ID | Fecha | Impedimento | Responsable | Estado | Resolución |
|---|---|---|---|---|---|
| IMP-01 | 10/11 | Solo `valentiniriar` tiene escritura en `github.com/valentiniriar/proyecto_demo_hia`; el resto no puede crear ramas ni PRs ni configurar protección | valentin iriarte | Abierto | Agregar a los 4 integrantes como colaboradores (rol *Write*; *Admin* a quien configure CI/protección) |
| IMP-02 | 10/11 | Al cierre del día 3 del Sprint 1 no había tareas iniciadas en el tablero | Equipo | Abierto | Daily y redistribución; lo no terminado pasa al Sprint 2 priorizando la base de datos |

## Decisiones técnicas

| ID | Fecha | Decisión | Motivo |
|---|---|---|---|
| DEC-01 | 07/11 | Sprints de 3–4 días hasta la defensa (semana del 16/11) | Plazo corto; permite 3 ciclos de review/retro |
| DEC-02 | 07/11 | Una épica por punto del enunciado (E01–E15) | Trazabilidad directa entre consigna, tickets y entregables |
| DEC-03 | 10/11 | Flujo `main` / `develop` / `feature/*` / `fix/*` con PR obligatorio y squash merge | Pedido por el enunciado y simple para 5 personas |
| DEC-04 | 10/11 | PostgreSQL con replicación por streaming (primario + réplica) | Motor ya usado por la app; replicación nativa sin software extra |
| DEC-05 | 10/11 | Publicación con Cloudflare Tunnel | No requiere abrir puertos del router; HTTPS y control de acceso incluidos |

## Cambios de alcance

| Fecha | Cambio | Motivo |
|---|---|---|
| | | |
