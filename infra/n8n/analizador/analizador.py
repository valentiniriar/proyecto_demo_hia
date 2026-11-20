#!/usr/bin/env python3
"""Analizador de rendimiento de GymHub (flujo 3 de n8n, informe asistido).

Componente Python que el TP pide para "analizar anomalías": n8n le manda las series de métricas que
juntó de Prometheus y recibe los hallazgos y un informe en Markdown. Sin dependencias externas ni
servicios de terceros (solo la biblioteca estándar): no sale nada a Internet.

    POST /analizar   {"desde": "...", "hasta": "...", "series": [
                        {"nombre": "...", "unidad": "%", "umbral_alto": 80, "umbral_bajo": null,
                         "valores": [[ts, valor], ...]}, ...]}
    GET  /salud      → {"estado": "ok"}

Detección por serie:
  - Umbral: último valor o pico fuera de umbral_alto / umbral_bajo (si la serie los define).
  - Puntos atípicos: z robusto = 0,6745·(x − mediana) / MAD; |z| > 3,5 (Iglewicz y Hoaglin). Se usa
    mediana y MAD en lugar de media y desvío porque un solo pico no "contamina" la referencia.
  - Tendencia: media de la última cuarta parte de la ventana contra la de las tres cuartas anteriores.
Severidad: critico (umbral superado al final), advertencia (picos, atípicos o tendencia fuerte), ok.
"""
import json
import statistics
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

Z_ATIPICO = 3.5
TENDENCIA_FUERTE = 0.5      # +50 % entre la parte final y el resto de la ventana
MAX_CUERPO = 5 * 1024 * 1024
ORDEN = {"critico": 2, "advertencia": 1, "ok": 0}


def _fmt(v, unidad):
    if v is None:
        return "-"
    if unidad == "bytes":
        for u in ("B", "KB", "MB", "GB", "TB"):
            if abs(v) < 1024:
                return f"{v:.1f} {u}"
            v /= 1024
        return f"{v:.1f} PB"
    if unidad == "s":
        return f"{v * 1000:.0f} ms" if v < 1 else f"{v:.2f} s"
    return f"{v:.2f}{(' ' + unidad) if unidad else ''}"


def analizar_serie(s):
    nombre = str(s.get("nombre", "sin nombre"))[:120]
    unidad = str(s.get("unidad", ""))[:10]
    alto, bajo = s.get("umbral_alto"), s.get("umbral_bajo")
    valores = []
    for par in s.get("valores", []):
        try:
            v = float(par[1])
        except (TypeError, ValueError, IndexError):
            continue
        if v == v and abs(v) != float("inf"):     # descarta NaN e infinitos
            valores.append(v)

    r = {"nombre": nombre, "unidad": unidad, "muestras": len(valores), "severidad": "ok", "hallazgos": []}
    if not valores:
        r["severidad"] = "advertencia"
        r["hallazgos"].append("Sin datos en la ventana: el exporter o el servicio podría estar caído.")
        return r

    mediana = statistics.median(valores)
    mad = statistics.median([abs(v - mediana) for v in valores])
    ultimo, maximo, minimo = valores[-1], max(valores), min(valores)
    r.update({"ultimo": ultimo, "mediana": mediana, "maximo": maximo, "minimo": minimo,
              "promedio": statistics.fmean(valores)})

    def subir(sev):
        if ORDEN[sev] > ORDEN[r["severidad"]]:
            r["severidad"] = sev

    if alto is not None:
        if ultimo > alto:
            subir("critico")
            r["hallazgos"].append(f"Último valor {_fmt(ultimo, unidad)} por encima del umbral {_fmt(alto, unidad)}.")
        elif maximo > alto:
            subir("advertencia")
            r["hallazgos"].append(f"Pico de {_fmt(maximo, unidad)} por encima del umbral {_fmt(alto, unidad)} (ya normalizado).")
    if bajo is not None:
        if ultimo < bajo:
            subir("critico")
            r["hallazgos"].append(f"Último valor {_fmt(ultimo, unidad)} por debajo del mínimo esperado {_fmt(bajo, unidad)}.")
        elif minimo < bajo:
            subir("advertencia")
            r["hallazgos"].append(f"Caída a {_fmt(minimo, unidad)}, por debajo de {_fmt(bajo, unidad)} (ya normalizado).")

    if mad > 0 and len(valores) >= 12:
        atipicos = [v for v in valores if abs(0.6745 * (v - mediana) / mad) > Z_ATIPICO]
        if atipicos:
            subir("advertencia")
            r["hallazgos"].append(
                f"{len(atipicos)} muestras atípicas (z robusto > {Z_ATIPICO}); la más extrema: "
                f"{_fmt(max(atipicos, key=lambda v: abs(v - mediana)), unidad)} con mediana {_fmt(mediana, unidad)}.")

    if len(valores) >= 8:
        corte = len(valores) * 3 // 4
        antes, final = statistics.fmean(valores[:corte]), statistics.fmean(valores[corte:])
        if antes > 0 and (final - antes) / antes > TENDENCIA_FUERTE:
            subir("advertencia")
            r["hallazgos"].append(
                f"Tendencia en alza: el último cuarto de la ventana promedia {_fmt(final, unidad)} "
                f"contra {_fmt(antes, unidad)} antes (+{(final - antes) / antes:.0%}).")
    return r


def informe(cuerpo):
    resultados = [analizar_serie(s) for s in cuerpo.get("series", [])[:50]]
    general = max((r["severidad"] for r in resultados), key=ORDEN.get, default="ok")
    ahora = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M UTC")
    icono = {"ok": "🟢", "advertencia": "🟠", "critico": "🔴"}
    lineas = [
        "# Informe de rendimiento de GymHub",
        "",
        f"- **Generado:** {ahora} por el flujo 3 de n8n (analizador Python, sin servicios externos).",
        f"- **Ventana analizada:** {cuerpo.get('desde', '?')} → {cuerpo.get('hasta', '?')}.",
        f"- **Estado general:** {icono[general]} **{general.upper()}**.",
        "",
        "| Métrica | Estado | Último | Mediana | Máximo | Muestras |",
        "|---|---|---|---|---|---|",
    ]
    for r in resultados:
        u = r["unidad"]
        lineas.append(f"| {r['nombre']} | {icono[r['severidad']]} {r['severidad']} | {_fmt(r.get('ultimo'), u)} | "
                      f"{_fmt(r.get('mediana'), u)} | {_fmt(r.get('maximo'), u)} | {r['muestras']} |")
    lineas += ["", "## Hallazgos", ""]
    hallazgos = [(r["nombre"], h) for r in resultados for h in r["hallazgos"]]
    lineas += [f"- **{n}:** {h}" for n, h in hallazgos] or ["- Sin anomalías detectadas en la ventana."]
    lineas += ["", "## Método", "",
               "Umbrales por métrica, puntos atípicos por z robusto (mediana y MAD, |z| > 3,5) y tendencia "
               "(último cuarto de la ventana contra el resto). Las cifras salen de Prometheus; el informe no "
               "reemplaza la revisión de una persona."]
    return {"estado_general": general, "hallazgos": len(hallazgos), "series": resultados,
            "markdown": "\n".join(lineas) + "\n"}


class Manejador(BaseHTTPRequestHandler):
    server_version = "gymhub-analizador/1.0"

    def _responder(self, codigo, datos):
        cuerpo = json.dumps(datos, ensure_ascii=False).encode()
        self.send_response(codigo)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(cuerpo)))
        self.end_headers()
        self.wfile.write(cuerpo)

    def do_GET(self):
        if self.path == "/salud":
            return self._responder(200, {"estado": "ok"})
        self._responder(404, {"error": "no encontrado"})

    def do_POST(self):
        if self.path != "/analizar":
            return self._responder(404, {"error": "no encontrado"})
        largo = int(self.headers.get("Content-Length") or 0)
        if largo <= 0 or largo > MAX_CUERPO:
            return self._responder(413 if largo > MAX_CUERPO else 400, {"error": "cuerpo vacío o demasiado grande"})
        try:
            cuerpo = json.loads(self.rfile.read(largo))
            if not isinstance(cuerpo, dict) or not isinstance(cuerpo.get("series"), list):
                raise ValueError("se esperaba {\"series\": [...]}")
        except ValueError as e:
            return self._responder(400, {"error": f"JSON inválido: {e}"})
        self._responder(200, informe(cuerpo))

    def log_message(self, fmt, *args):
        print(f"[analizador] {self.address_string()} {fmt % args}", flush=True)


if __name__ == "__main__":
    ThreadingHTTPServer(("0.0.0.0", 8000), Manejador).serve_forever()
