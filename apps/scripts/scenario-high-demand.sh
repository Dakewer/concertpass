#!/usr/bin/env bash
# Escenario 2: alta demanda. Envia mas reservaciones de las que hay boletos, en paralelo,
# y comprueba que NO hay sobreventa: los primeros obtienen boleto, el resto queda rejected.
#
# Uso: scenario-high-demand.sh [--concert ID] [--type TIPO] [--requests N] [--quantity Q]
#                              [--concurrency C] [--workers W] [--timeout SEG]
#   --workers W   escala ticket-worker a W replicas durante la prueba (por ejemplo 3)
#                 y lo regresa a su valor original al terminar.
# Por defecto: bad-bunny-gdl / vip / 60 reservas de 1 boleto (capacidad vip = 50), 20 en paralelo.
set -euo pipefail
# shellcheck source=lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

CONCERT="${CONCERT:-bad-bunny-gdl}"
TICKET_TYPE="${TICKET_TYPE:-vip}"
REQUESTS="${REQUESTS:-60}"
QUANTITY="${QUANTITY:-1}"
CONCURRENCY="${CONCURRENCY:-20}"
WORKERS="${WORKERS:-3}"
TIMEOUT="${TIMEOUT:-600}"

while [ $# -gt 0 ]; do
  case "$1" in
    --concert)     CONCERT="${2:?falta valor}";     shift 2 ;;
    --type)        TICKET_TYPE="${2:?falta valor}"; shift 2 ;;
    --requests)    REQUESTS="${2:?falta valor}";    shift 2 ;;
    --quantity)    QUANTITY="${2:?falta valor}";    shift 2 ;;
    --concurrency) CONCURRENCY="${2:?falta valor}"; shift 2 ;;
    --workers)     WORKERS="${2:?falta valor}";     shift 2 ;;
    --timeout)     TIMEOUT="${2:?falta valor}";     shift 2 ;;
    -h|--help)     usage_from_header "$0"; exit 0 ;;
    *) die "Opcion desconocida: $1" ;;
  esac
done

safe_ident concierto "$CONCERT"
safe_ident tipo "$TICKET_TYPE"
for pair in "requests:$REQUESTS" "quantity:$QUANTITY" "concurrency:$CONCURRENCY"; do
  [[ "${pair#*:}" =~ ^[0-9]+$ && "${pair#*:}" -gt 0 ]] || die "--${pair%%:*} debe ser un entero positivo"
done
[ -z "$WORKERS" ] || [[ "$WORKERS" =~ ^[0-9]+$ && "$WORKERS" -gt 0 ]] || die "--workers debe ser un entero positivo"

load_config
resolve_api_url

prev_replicas=""
restore_workers() {
  if [ -n "$prev_replicas" ]; then
    step "Restaurando ticket-worker a $prev_replicas replica(s)"
    k scale deployment/ticket-worker --replicas="$prev_replicas" || true
  fi
}

if [ -n "$WORKERS" ]; then
  prev_replicas="$(k get deployment ticket-worker -o jsonpath='{.spec.replicas}')"
  trap restore_workers EXIT
  step "Escalando ticket-worker a $WORKERS replicas (antes: $prev_replicas)"
  k scale deployment/ticket-worker --replicas="$WORKERS"
  k rollout status deployment/ticket-worker --timeout=180s
  k get pods -l app=ticket-worker -o wide
fi

step "Estado inicial de $CONCERT / $TICKET_TYPE"
capacity="$(dynamo_capacity "$CONCERT" "$TICKET_TYPE")"
baseline="$(sold_count "$CONCERT" "$TICKET_TYPE")"
log "Capacidad (DynamoDB): $capacity   Ya vendidos (RDS): $baseline   Disponibles: $((capacity - baseline))"
log "Se enviaran $REQUESTS reservaciones de $QUANTITY boleto(s) = $((REQUESTS * QUANTITY)) boletos solicitados"
if [ $((REQUESTS * QUANTITY)) -le $((capacity - baseline)) ]; then
  warn "Hay boletos de sobra: no habra rejected. Sube --requests o limpia/ajusta con evidence.sh reset."
fi

# ---- Generador de carga ---------------------------------------------------------------------
RESULTS="$(mktemp)"
RUN_ID="$(date +%s)"
trap 'rm -f "$RESULTS"; restore_workers' EXIT
export RESULTS RUN_ID API_URL CONCERT TICKET_TYPE QUANTITY

reserve_one() {
  local i="$1" body out code json id
  body="$(printf '{"concert_id":"%s","user_id":"usr_%s_%s","ticket_type":"%s","quantity":%s}' \
    "$CONCERT" "$RUN_ID" "$i" "$TICKET_TYPE" "$QUANTITY")"
  if ! out="$(curl -sS --max-time 30 -w '\n%{http_code}' -X POST "$API_URL/reserve" \
      -H 'Content-Type: application/json' -d "$body" 2>/dev/null)"; then
    echo "ERR -" >> "$RESULTS"
    return 0
  fi
  code="${out##*$'\n'}"
  json="${out%$'\n'*}"
  id="$(printf '%s' "$json" | sed -n 's/.*"reservation_id" *: *"\([^"]*\)".*/\1/p')"
  echo "$code ${id:--}" >> "$RESULTS"
}
export -f reserve_one

step "Enviando $REQUESTS reservaciones con $CONCURRENCY peticiones en paralelo"
t0=$SECONDS
seq 1 "$REQUESTS" | xargs -P "$CONCURRENCY" -I{} bash -c 'reserve_one "$1"' _ {}
elapsed=$((SECONDS - t0))
[ "$elapsed" -gt 0 ] || elapsed=1

accepted="$(grep -c '^200 ' "$RESULTS" || true)"
failed=$((REQUESTS - accepted))
log "Peticiones aceptadas por la API (HTTP 200): $accepted   con error: $failed   (~$((REQUESTS / elapsed)) req/s, ${elapsed}s)"
[ "$accepted" -gt 0 ] || die "Ninguna reservacion fue aceptada por la API."

ids=()
while IFS= read -r line; do
  ids+=("$line")
done < <(awk '$1 == "200" && $2 != "-" {print $2}' "$RESULTS")
idlist="$(sql_id_list "${ids[@]}")"

# ---- Esperar a que el worker procese todo --------------------------------------------------
step "Procesamiento del worker (consulta a RDS cada 3 s)"
deadline=$((SECONDS + TIMEOUT))
settled=0
while :; do
  open_count="$(db_scalar "SELECT COUNT(*) FROM reservations WHERE reservation_id IN ($idlist) AND status IN ('pending', 'booked')")"
  summary="$(db_scalar "SELECT COALESCE(string_agg(status || '=' || n, '   ' ORDER BY status), 'sin filas') FROM (SELECT status, COUNT(*) AS n FROM reservations WHERE reservation_id IN ($idlist) GROUP BY status) s")"
  log "  $summary"
  if [ "$open_count" = "0" ]; then settled=1; break; fi
  [ "$SECONDS" -lt "$deadline" ] || break
  sleep 3
done

# ---- Evidencia y verificacion --------------------------------------------------------------
step "Resultado por estado (solo esta corrida)"
db_query "SELECT status, COUNT(*) AS reservas, SUM(quantity) AS boletos FROM reservations WHERE reservation_id IN ($idlist) GROUP BY status ORDER BY status"

step "Ejemplos de reservaciones rejected en RDS"
db_query "SELECT reservation_id, user_id, quantity, status, updated_at FROM reservations WHERE reservation_id IN ($idlist) AND status = 'rejected' ORDER BY updated_at LIMIT 8"

step "Verificacion de no sobreventa"
final_sold="$(sold_count "$CONCERT" "$TICKET_TYPE")"
log "Vendidos (booked + confirmed) = $final_sold   Capacidad = $capacity"

verdict=0
if [ "$settled" -ne 1 ]; then
  log "FAIL: quedaron reservaciones sin procesar despues de ${TIMEOUT}s (Â¿el worker esta corriendo?)."
  verdict=1
fi
if [ "$final_sold" -gt "$capacity" ]; then
  log "FAIL: SOBREVENTA: se vendieron $final_sold boletos y la capacidad es $capacity."
  verdict=1
else
  log "OK: no hay sobreventa ($final_sold <= $capacity)."
fi
if [ "$QUANTITY" -eq 1 ]; then
  want=$((baseline + accepted))
  [ "$want" -le "$capacity" ] || want="$capacity"
  if [ "$final_sold" -eq "$want" ]; then
    log "OK: se vendieron exactamente los boletos esperados ($want)."
  else
    log "FAIL: se esperaban $want boletos vendidos y hay $final_sold."
    verdict=1
  fi
fi
if [ "$failed" -gt 0 ]; then
  log "FAIL: $failed peticiones no devolvieron HTTP 200 (revisa los logs de ticket-api)."
  verdict=1
fi

step "Resultado"
if [ "$verdict" -eq 0 ]; then
  log "PASS"
else
  log "FAIL"
fi
exit "$verdict"
