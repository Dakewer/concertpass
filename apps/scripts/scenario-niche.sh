#!/usr/bin/env bash
# Escenario 1: concierto de nicho (poca demanda).
# Envia pocas reservaciones, todas deben terminar en "confirmed".
#
# Uso: scenario-niche.sh [--concert ID] [--type TIPO] [--count N] [--quantity Q] [--timeout SEG]
# Por defecto: artista-nicho-cdmx / general / 4 reservas de 1 boleto (capacidad general = 8).
set -euo pipefail
# shellcheck source=lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

CONCERT="${CONCERT:-artista-nicho-cdmx}"
TICKET_TYPE="${TICKET_TYPE:-general}"
COUNT="${COUNT:-4}"
QUANTITY="${QUANTITY:-1}"
TIMEOUT="${TIMEOUT:-90}"

while [ $# -gt 0 ]; do
  case "$1" in
    --concert)  CONCERT="${2:?falta valor}";     shift 2 ;;
    --type)     TICKET_TYPE="${2:?falta valor}"; shift 2 ;;
    --count)    COUNT="${2:?falta valor}";       shift 2 ;;
    --quantity) QUANTITY="${2:?falta valor}";    shift 2 ;;
    --timeout)  TIMEOUT="${2:?falta valor}";     shift 2 ;;
    -h|--help)  usage_from_header "$0"; exit 0 ;;
    *) die "Opcion desconocida: $1" ;;
  esac
done

safe_ident concierto "$CONCERT"
safe_ident tipo "$TICKET_TYPE"
[[ "$COUNT" =~ ^[0-9]+$ && "$COUNT" -gt 0 ]]       || die "--count debe ser un entero positivo"
[[ "$QUANTITY" =~ ^[0-9]+$ && "$QUANTITY" -gt 0 ]] || die "--quantity debe ser un entero positivo"

load_config
resolve_api_url

step "Estado inicial de $CONCERT / $TICKET_TYPE"
capacity="$(dynamo_capacity "$CONCERT" "$TICKET_TYPE")"
sold="$(sold_count "$CONCERT" "$TICKET_TYPE")"
log "Capacidad (DynamoDB): $capacity   Ya vendidos (RDS): $sold   Disponibles: $((capacity - sold))"
if [ $((sold + COUNT * QUANTITY)) -gt "$capacity" ]; then
  die "No alcanza la capacidad restante para este escenario. Limpia con: evidence.sh reset"
fi

step "Enviando $COUNT reservaciones (POST /reserve)"
RUN_ID="$(date +%s)"
ids=()
for i in $(seq 1 "$COUNT"); do
  body="$(printf '{"concert_id":"%s","user_id":"usr_nicho_%s_%s","ticket_type":"%s","quantity":%s}' \
    "$CONCERT" "$RUN_ID" "$i" "$TICKET_TYPE" "$QUANTITY")"
  resp="$(curl -sS --max-time 20 -w '\n%{http_code}' -X POST "$API_URL/reserve" \
    -H 'Content-Type: application/json' -d "$body")" || die "Fallo la peticion $i a $API_URL/reserve"
  code="${resp##*$'\n'}"
  json="${resp%$'\n'*}"
  [ "$code" = "200" ] || die "POST /reserve devolvio HTTP $code: $json"
  id="$(printf '%s' "$json" | sed -n 's/.*"reservation_id" *: *"\([^"]*\)".*/\1/p')"
  [ -n "$id" ] || die "Respuesta sin reservation_id: $json"
  ids+=("$id")
  log "  #$i -> $id"
done

step "Esperando estado final (GET /reservation/{id})"
confirmed=0
for id in "${ids[@]}"; do
  deadline=$((SECONDS + TIMEOUT))
  status=""
  while :; do
    status="$(status_of "$id")"
    case "$status" in confirmed|rejected) break ;; esac
    if [ "$SECONDS" -ge "$deadline" ]; then
      status="${status:-sin-respuesta}"
      break
    fi
    sleep 2
  done
  log "  $id -> $status"
  [ "$status" = "confirmed" ] && confirmed=$((confirmed + 1))
done

idlist="$(sql_id_list "${ids[@]}")"
step "Evidencia en RDS"
db_query "SELECT reservation_id, user_id, ticket_type, quantity, status FROM reservations WHERE reservation_id IN ($idlist) ORDER BY created_at"

step "Evidencia en DynamoDB (capacidad del concierto)"
aws --region "$REGION" dynamodb get-item --table-name "$EVENTS_TABLE" \
  --key "{\"concert_id\":{\"S\":\"$CONCERT\"}}" \
  --query 'Item.{concert_id:concert_id.S,name:name.S,recinto:recinto.S,capacity:{floor:capacity.M.floor.N,vip:capacity.M.vip.N,general:capacity.M.general.N}}' \
  --output json

step "Resultado"
if [ "$confirmed" -eq "$COUNT" ]; then
  log "PASS: las $COUNT reservaciones terminaron en confirmed."
else
  log "FAIL: solo $confirmed de $COUNT terminaron en confirmed."
  exit 1
fi
