# Analizador de rendimiento (flujo 3 de n8n). Solo biblioteca estándar de Python: sin pip install.
FROM python:3.13-alpine
WORKDIR /app
COPY analizador.py .
# Usuario sin privilegios.
RUN adduser -D -H -u 10001 analizador
USER analizador
EXPOSE 8000
HEALTHCHECK --interval=30s --timeout=3s CMD wget -qO- http://127.0.0.1:8000/salud >/dev/null || exit 1
CMD ["python", "-u", "analizador.py"]
