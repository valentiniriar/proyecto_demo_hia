#!/usr/bin/env bash
# Pruebas de seguridad controladas de GymHub (SCRUM-81).
# SOLO contra nuestro entorno local de prueba. Requiere el stack levantado y los datos demo.
#   bash docs/evidencias/SCRUM-81/pruebas-seguridad.sh [URL_BASE]   (default http://localhost:8080)
set -uo pipefail
BASE="${1:-http://localhost:8080}"
API="$BASE/api"
PASS_DEMO="${PASS_DEMO:-demo1234}"
R=$((RANDOM % 250 + 1))   # segundo octeto de las IPs simuladas, distinto en cada corrida
j() { node -e "let s='';process.stdin.on('data',d=>s+=d).on('end',()=>{try{const j=JSON.parse(s);console.log($1)}catch(e){console.log('')}})"; }
code() { curl -s -o /dev/null -w "%{http_code}" "$@"; }
ok=0; fail=0
check() { # check "descripcion" esperado obtenido
  if [ "$2" = "$3" ]; then ok=$((ok+1)); printf "  ✔ %-78s esperado %s, obtuvo %s\n" "$1" "$2" "$3";
  else fail=$((fail+1)); printf "  ✖ %-78s esperado %s, obtuvo %s\n" "$1" "$2" "$3"; fi; }
login() { curl -s -X POST "$API/auth/login" -H 'Content-Type: application/json' -H "X-Forwarded-For: $3" -d "{\"email\":\"$1\",\"password\":\"$2\"}" | j "j.token||''"; }

echo "== Preparación (IP de origen simulada por X-Forwarded-For para no mezclar rate limits)"
T_ADMIN=$(login admin@demo.com "$PASS_DEMO" 10.$R.0.1)
T_SOCIO=$(login socio@demo.com "$PASS_DEMO" 10.$R.0.2)
T_ENTR=$(login entrenador@demo.com "$PASS_DEMO" 10.$R.0.3)
[ -n "$T_ADMIN" ] && [ -n "$T_SOCIO" ] && [ -n "$T_ENTR" ] && echo "  tokens admin/socio/entrenador obtenidos" || { echo "  ✖ no se pudo iniciar sesión con los usuarios demo"; exit 1; }

# Dos socios víctima, cada uno con su suscripción y una cuota impaga.
SUF=$(date +%s)
nueva_victima() { # $1 sufijo -> imprime "token idUsuario tarifaId"
  local email="victima$1@demo.com" t id tar
  curl -s -o /dev/null -X POST "$API/usuarios" -H 'Content-Type: application/json' -H "X-Forwarded-For: 10.$R.0.9"     -d "{\"nombre\":\"Victima\",\"apellido\":\"Prueba\",\"dni\":\"9${1: -7}\",\"email\":\"$email\",\"password\":\"Victima123\"}"
  t=$(login "$email" Victima123 "10.$R.0.9")
  id=$(echo "$t" | cut -d. -f2 | tr '_-' '/+' | base64 -d 2>/dev/null | j "j.id")
  curl -s -o /dev/null -X POST "$API/suscripciones" -H "Authorization: Bearer $T_ADMIN" -H 'Content-Type: application/json'     -d "{\"fecha_inicio\":\"2026-11-01\",\"fecha_fin\":\"2026-11-30\",\"precio\":\"25000\",\"activo\":true,\"usuario\":{\"id\":$id}}"
  tar=$(curl -s "$API/tarifas/impagas/$id" -H "Authorization: Bearer $T_ADMIN" | j "(Array.isArray(j)?j:[])[0]?.id||''")
  echo "$t $id $tar"
}
read -r T_VICT ID_VICT TARIFA_VICT <<< "$(nueva_victima "$SUF")"
read -r T_VICT2 ID_VICT2 TARIFA_VICT2 <<< "$(nueva_victima "$((SUF+1))")"
echo "  víctima A id=$ID_VICT cuota impaga tarifaId=$TARIFA_VICT · víctima B id=$ID_VICT2 cuota impaga tarifaId=$TARIFA_VICT2"

echo; echo "== 1. Inyección SQL"
check "login con email \"' OR '1'='1\" (rechazado por validación)"  422 "$(code -X POST "$API/auth/login" -H 'Content-Type: application/json' -H 'X-Forwarded-For: 10.$R.1.1' -d "{\"email\":\"' OR '1'='1\",\"password\":\"x\"}")"
check "login con email \"admin@demo.com'--\" (rechazado por validación)" 422 "$(code -X POST "$API/auth/login" -H 'Content-Type: application/json' -H 'X-Forwarded-For: 10.$R.1.2' -d "{\"email\":\"admin@demo.com'--\",\"password\":\"x\"}")"
check "login con password \"' OR 1=1--\" (no autentica)"          401 "$(code -X POST "$API/auth/login" -H 'Content-Type: application/json' -H 'X-Forwarded-For: 10.$R.1.3' -d "{\"email\":\"admin@demo.com\",\"password\":\"' OR 1=1--\"}")"
check "GET /usuarios/:dni con \"1' OR '1'='1\" (sin fuga de datos)" 404 "$(code "$API/usuarios/1'%20OR%20'1'='1" -H "Authorization: Bearer $T_ADMIN")"
check "GET /tarifas/impagas/:id con \"1 OR 1=1\" (sin fuga)"        400 "$(code "$API/tarifas/impagas/1%20OR%201=1" -H "Authorization: Bearer $T_ADMIN")"
NUT=$(code "$API/nutricion/buscar?q=%27%20UNION%20SELECT%20password_hash%20FROM%20usuarios--" -H "Authorization: Bearer $T_SOCIO"); echo "  nutrición con UNION SELECT respondió $NUT (503 = Open Food Facts no disponible)"
check "nutrición ?q=' UNION SELECT ... (sin error interno 500)" "no" "$([ "$NUT" = 500 ] && echo si || echo no)"

echo; echo "== 2. Fuerza bruta en login (rate limit SCRUM-65)"
seq_codes=""; for i in 1 2 3 4 5 6 7; do seq_codes+="$(code -X POST "$API/auth/login" -H 'Content-Type: application/json' -H 'X-Forwarded-For: 10.$R.2.1' -d '{"email":"admin@demo.com","password":"intento'$i'"}') "; done
echo "  7 intentos fallidos desde la misma IP: $seq_codes"
check "el 6.º intento fallido se bloquea" 429 "$(echo $seq_codes | awk '{print $6}')"
check "otra IP no queda bloqueada"         401 "$(code -X POST "$API/auth/login" -H 'Content-Type: application/json' -H 'X-Forwarded-For: 10.$R.2.2' -d '{"email":"admin@demo.com","password":"otra"}')"

echo; echo "== 3. Escalamiento de rol (socio llamando endpoints de admin/entrenador)"
check "socio GET /usuarios"                       403 "$(code "$API/usuarios" -H "Authorization: Bearer $T_SOCIO")"
check "socio GET /usuarios/10000001 (DNI admin)"  403 "$(code "$API/usuarios/10000001" -H "Authorization: Bearer $T_SOCIO")"
check "socio DELETE /usuarios/10000001"           403 "$(code -X DELETE "$API/usuarios/10000001" -H "Authorization: Bearer $T_SOCIO")"
check "socio GET /pagos (todos los pagos)"        403 "$(code "$API/pagos" -H "Authorization: Bearer $T_SOCIO")"
check "socio GET /tarifas (todas las cuotas)"     403 "$(code "$API/tarifas" -H "Authorization: Bearer $T_SOCIO")"
check "socio POST /tarifas"                       403 "$(code -X POST "$API/tarifas" -H "Authorization: Bearer $T_SOCIO" -H 'Content-Type: application/json' -d '{}')"
check "socio POST /suscripciones"                 403 "$(code -X POST "$API/suscripciones" -H "Authorization: Bearer $T_SOCIO" -H 'Content-Type: application/json' -d '{}')"
check "socio GET /dashboard"                      403 "$(code "$API/dashboard/stats" -H "Authorization: Bearer $T_SOCIO")"
check "entrenador DELETE /usuarios/10000003"      403 "$(code -X DELETE "$API/usuarios/10000003" -H "Authorization: Bearer $T_ENTR")"
FORJADO="$(echo "$T_SOCIO" | cut -d. -f1).$(printf '{"id":1,"email":"admin@demo.com","estado":true}' | base64 | tr -d '=\n' | tr '/+' '_-').$(echo "$T_SOCIO" | cut -d. -f3)"
check "JWT con payload alterado (id=1) y firma vieja" 401 "$(code "$API/usuarios" -H "Authorization: Bearer $FORJADO")"
NONE="$(printf '{"alg":"none","typ":"JWT"}' | base64 | tr -d '=\n' | tr '/+' '_-').$(printf '{"id":1}' | base64 | tr -d '=\n' | tr '/+' '_-')."
check "JWT con alg=none"                              401 "$(code "$API/usuarios" -H "Authorization: Bearer $NONE")"

echo; echo "== 4. IDOR (acceso a datos de otro socio)"
MIS=$(curl -s "$API/tarifas/mis-tarifas" -H "Authorization: Bearer $T_SOCIO" | j "JSON.stringify((Array.isArray(j)?j:(j.tarifas||j.data||[])).map(t=>t.id))")
echo "  cuotas que ve el socio demo en /mis-tarifas: $MIS (la de la víctima es $TARIFA_VICT)"
check "/mis-tarifas no incluye la cuota de la víctima" "no" "$(echo "$MIS" | grep -qw "$TARIFA_VICT" && echo si || echo no)"
check "socio GET /tarifas/impagas/<id víctima>"        403 "$(code "$API/tarifas/impagas/$ID_VICT" -H "Authorization: Bearer $T_SOCIO")"
R2=$(curl -s -w ' HTTP%{http_code}' -X POST "$API/pagos" -H "Authorization: Bearer $T_VICT2" -H 'Content-Type: application/json' \
  -d "{\"fecha\":\"2026-11-13\",\"transaccion\":\"SIN-PAGAR\",\"monto\":\"1\",\"activo\":true,\"tarifa\":{\"id\":$TARIFA_VICT2}}")
echo "  la víctima B marca su propia cuota como pagada sin pasar por MercadoPago: $R2"
check "socio no puede marcar su cuota como paga sin un pago verificado" 400 "$(echo "$R2" | grep -o 'HTTP[0-9]*' | tr -d HTTP)"

R=$(curl -s -w ' HTTP%{http_code}' -X POST "$API/pagos" -H "Authorization: Bearer $T_SOCIO" -H 'Content-Type: application/json' \
  -d "{\"fecha\":\"2026-11-13\",\"transaccion\":\"FRAUDE-PRUEBA\",\"monto\":\"1\",\"activo\":true,\"tarifa\":{\"id\":$TARIFA_VICT}}")
echo "  socio demo registra un pago de \$1 para la cuota de la víctima A: $R"
check "socio no puede pagar (marcar) la cuota de otro socio" 403 "$(echo "$R" | grep -o 'HTTP[0-9]*' | tr -d HTTP)"
echo; echo "== Resultado: $ok OK, $fail con hallazgo"
