# Reporte de disponibilidad de la publicación — ventana 25m

Generado: 2026-11-13 13:39     con `infra/monitoring/reporte-disponibilidad.sh`

| Indicador | Valor |
|---|---|
| URL monitoreada (blackbox-publico) | https://<url-efimera>.trycloudflare.com/api/health (up) |
| **Disponibilidad** (`avg_over_time(probe_success)`) | **46.154 %** |
| Sondas realizadas / fallidas (cada 30 s) | 13 / 7 |
| Latencia de la sonda: promedio / máxima | 3.901 s / 8.843 s |
| Días hasta el vencimiento del certificado HTTPS | 51.2 |
| Conexiones activas del túnel con Cloudflare | 1 |
| Requests servidos por el túnel / con error hacia el origen | 19 / 13 |
| Respuestas 5xx registradas por Nginx | 0 |
| Requests que el túnel no pudo entregar al origen (cloudflared → 502 al visitante) | 13 |
| Eventos de corte/reconexión del túnel (logs de cloudflared) | 0 |
| Alertas de publicación activas ahora | GymHubTunelErroresOrigen=firing |

## Últimas respuestas 5xx (Nginx)

```
(ninguna)
```

## Errores hacia el origen (cloudflared)

```
2026-11-13T16:34:26Z ERR Request failed error="Unable to reach the origin service. The service may be down or it may not be responding to traffic from
2026-11-13T16:34:57Z ERR Request failed error="Unable to reach the origin service. The service may be down or it may not be responding to traffic from
2026-11-13T16:35:22Z ERR Request failed error="Unable to reach the origin service. The service may be down or it may not be responding to traffic from
2026-11-13T16:35:56Z ERR Request failed error="Unable to reach the origin service. The service may be down or it may not be responding to traffic from
2026-11-13T16:36:26Z ERR Request failed error="Unable to reach the origin service. The service may be down or it may not be responding to traffic from
```

## Eventos del túnel (cloudflared)

```
2026-11-13T16:32:02Z INF Registered tunnel connection connIndex=0 connection=68124cbf-56d8-40f6-8fc1-f6c82006b3a6 event=0 ip=198.41.200.23 location=eze01 protocol=quic
```
