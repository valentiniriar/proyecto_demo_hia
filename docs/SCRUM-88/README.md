# SCRUM-88 — entrega para presentación GymHub HIA 2026

**Archivos:**

- `Presentacion_GymHub_HIA_2026.pptx`: diapositivas editables, 14 diapositivas de exposición + 1 de plan B.
- `Presentacion_GymHub_HIA_2026.pdf`: copia de las diapositivas para consultar sin PowerPoint.
- `Guion_20_minutos_GymHub.pdf`: guion imprimible con reparto 5 × 4 minutos, preguntas y plan B.
- `guion-y-plan-b.md`: fuente versionable en GitHub, con tiempos, enunciados y acciones en vivo.

**No se incluyeron archivos .env, contraseñas ni secretos.** Los datos de disponibilidad corresponden a un entorno local comprobado; no sustituyen las validaciones de Compose integral, túnel público, Mantis, Nextcloud o réplica.

**Subida a GitHub:** descomprimir el ZIP desde la raíz del repo estando en `docs/SCRUM-88-presentacion`; revisar `git status`, confirmar solo `docs/SCRUM-88/`, hacer commit y push; abrir PR a `develop`.

**Nota de Jira:** este material completa la documentación de presentación y el plan de demo. La aceptación global de SCRUM-88 requiere también validación del equipo de la demo completa y sus integraciones, si el docente lo exige; no declararla probada solo por crear archivos.


---

## Actualización de estado verificado para defensa (corte 18/11/2026)

1. **Pull Requests fusionados en `develop`:** además de los PR iniciales (`#1`, `#7`–`#12`), ya están fusionados `#24` (Compose), `#25` (workflow backup exportado), `#29` (Grafana), `#30` (Alertmanager), `#31` (presentación), `#47`–`#51` (alertas/seguridad/auditoría), `#52` (exporter, reglas y paneles de réplica PostgreSQL), `#53` (dataset 6M) y `#54` (análisis de consultas con `pgBadger`).
2. **Réplica PostgreSQL operativa (`SCRUM-45/66/67`):** contenedor `gymhub-replica-verificada` corriendo en modo `streaming` y solo lectura (`pg_is_in_recovery() = t`), con lag puntual de `0 bytes`, monitoreado por `postgres-replica` (`up=1`, `pg_up=1`) sin tocar el volumen principal `proyecto_demo_hia-main_db_data`.
3. **Circuito Webhook → n8n → MantisBT comprobado (`SCRUM-68/76`):** prueba controlada ejecutada contra `http://127.0.0.1:5679/webhook/gymhub-scrum76-alertas` con autenticación `Bearer`: alta de incidencia única (`ID: 9` en MantisBT `:8990`), deduplicación verificada ante segundo `firing` con mismo `fingerprint` y nota automática de recuperación ante `resolved`.
4. **Alcance honesto (qué sigue pendiente / en manos del equipo):**
   - `blackbox-publico` (`0 series`): depende del túnel HTTPS público (`SCRUM-60`).
   - Panel 18 de SQL lentas en tiempo real (`pg_stat_statements`): requiere ventana de mantenimiento/reinicio coordinado del primario `demo_hia_db` (como alternativa se cuenta con el análisis offline `pgBadger` del PR `#54`).
   - Flujos n8n `SCRUM-77` (verificación automática de backups) y `SCRUM-78` (informe IA → Nextcloud): pendientes de instalación y prueba integral con el equipo.
