#!/usr/bin/env bash
# Evidencia para el video: estado de RDS, DynamoDB y SQS, y utilidades de demo.
#
# Uso: evidence.sh <comando> [argumentos]
#   rds [estado]   resumen de reservaciones por concierto/tipo/estado y ultimas filas;
#                  con un estado (p. ej. rejected) muestra las filas de ese estado
#   dynamodb       conciertos precargados y su capacidad por seccion
#   sqs            mensajes en la cola principal y en la DLQ
#   sqs-demo       demuestra que POST /reserve encola en SQS: pone el worker en 0 replicas,
#                  hace una reserva, muestra el mensaje en la cola (con su MessageGroupId),
#                  y vuelve a subir el worker para que se procese
#   reset [--yes]  borra todas las reservaciones y purga las colas (para repetir una demo)
#   all            rds + dynamodb + sqs
set -euo pipefail
# shellcheck source=lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

cmd="${1:-all}"
shift || true

show_rds() {
  local status="${1:-}"
  if [ -n "$status" ]; then
    safe_ident estado "$status"
    step "RDS: reservaciones con estado '$status' (primeras 20)"
    db_query "SELECT reservation_id, concert_id, ticket_type, quantity, status, updated_at FROM reservations WHERE status = '$status' ORDER BY updated_at LIMIT 20"
    db_query "SELECT COUNT(*) AS total_$status FROM reservations WHERE status = '$status'"
    return
  fi
  step "RDS: resumen por concierto / tipo / estado"
  db_query "SELECT concert_id, ticket_type, status, COUNT(*) AS reservas, SUM(quantity) AS boletos FROM reservations GROUP BY 1, 2, 3 ORDER BY 1, 2, 3"
  step "RDS: ultimas 10 reservaciones"
  db_query "SELECT reservation_id, concert_id, ticket_type, quantity, status, created_at FROM reservations ORDER BY created_at DESC LIMIT 10"
}

show_dynamodb() {
  step "DynamoDB: tabla $EVENTS_TABLE"
  aws --region "$REGION" dynamodb scan --table-name "$EVENTS_TABLE" \
    --query 'Items[].{concert_id:concert_id.S,name:name.S,date:date.S,recinto:recinto.S,capacity:{floor:capacity.M.floor.N,vip:capacity.M.vip.N,general:capacity.M.general.N}}' \
    --output json
}

queue_attrs() {
  aws --region "$REGION" sqs get-queue-attributes --queue-url "$1" \
    --attribute-names ApproximateNumberOfMessages ApproximateNumberOfMessagesNotVisible ApproximateNumberOfMessagesDelayed FifoQueue \
    --query Attributes --output json
}

dlq_url() {
  aws --region "$REGION" sqs get-queue-url --queue-name concertpass-reservations-dlq.fifo \
    --query QueueUrl --output text
}

show_sqs() {
  step "SQS: cola principal ($QUEUE_URL)"
  queue_attrs "$QUEUE_URL"
  step "SQS: cola de mensajes fallidos (DLQ)"
  queue_attrs "$(dlq_url)"
}

sqs_demo() {
  resolve_api_url
  local prev body resp code json id
  prev="$(k get deployment ticket-worker -o jsonpath='{.spec.replicas}')"
  restore() {
    step "Regresando ticket-worker a $prev replica(s)"
    k scale deployment/ticket-worker --replicas="$prev" || true
  }
  trap restore EXIT

  step "1. Deteniendo ticket-worker para que el mensaje se quede en la cola"
  k scale deployment/ticket-worker --replicas=0
  k wait --for=delete pod -l app=ticket-worker --timeout=150s || true
  k get pods

  step "2. POST /reserve"
  body='{"concert_id":"bad-bunny-gdl","user_id":"usr_demo_sqs","ticket_type":"general","quantity":1}'
  log "$body"
  resp="$(curl -sS --max-time 20 -w '\n%{http_code}' -X POST "$API_URL/reserve" \
    -H 'Content-Type: application/json' -d "$body")" || die "Fallo POST /reserve"
  code="${resp##*$'\n'}"; json="${resp%$'\n'*}"
  log "HTTP $code  $json"
  [ "$code" = "200" ] || die "POST /reserve no devolvio 200"
  id="$(printf '%s' "$json" | sed -n 's/.*"reservation_id" *: *"\([^"]*\)".*/\1/p')"

  step "3. El mensaje esta en la cola (el conteo de SQS es aproximado, espera unos segundos)"
  sleep 6
  queue_attrs "$QUEUE_URL"

  step "4. Contenido del mensaje (visibility-timeout 0: solo se mira, no se consume)"
  aws --region "$REGION" sqs receive-message --queue-url "$QUEUE_URL" --max-number-of-messages 1 \
    --visibility-timeout 0 --wait-time-seconds 5 --attribute-names All --output json

  step "5. Estado en RDS mientras no hay worker"
  db_query "SELECT reservation_id, concert_id, status FROM reservations WHERE reservation_id = '$id'"

  step "6. Encendiendo ticket-worker de nuevo"
  k scale deployment/ticket-worker --replicas="$prev"
  trap - EXIT
  k rollout status deployment/ticket-worker --timeout=180s
  local status="" deadline=$((SECONDS + 90))
  while :; do
    status="$(status_of "$id")"
    case "$status" in confirmed|rejected) break ;; esac
    [ "$SECONDS" -lt "$deadline" ] || break
    sleep 2
  done
  log "GET /reservation/$id -> ${status:-sin-respuesta}"
  queue_attrs "$QUEUE_URL"
}

reset_all() {
  local assume_yes=0
  [ "${1:-}" = "--yes" ] && assume_yes=1
  if [ "$assume_yes" -ne 1 ]; then
    read -r -p "Esto borra TODAS las reservaciones y purga las colas. ¿Continuar? [s/N] " answer
    case "$answer" in s|S|si|SI|y|Y) ;; *) log "Cancelado."; return 0 ;; esac
  fi
  step "Borrando reservaciones en RDS"
  db_query "DELETE FROM reservations"
  step "Purgando colas SQS (SQS solo permite una purga por minuto)"
  aws --region "$REGION" sqs purge-queue --queue-url "$QUEUE_URL" || warn "No se pudo purgar la cola principal."
  aws --region "$REGION" sqs purge-queue --queue-url "$(dlq_url)" || warn "No se pudo purgar la DLQ."
}

case "$cmd" in -h|--help) usage_from_header "$0"; exit 0 ;; esac
load_config
case "$cmd" in
  rds)        show_rds "${1:-}" ;;
  dynamodb)   show_dynamodb ;;
  sqs)        show_sqs ;;
  sqs-demo)   sqs_demo ;;
  reset)      reset_all "${1:-}" ;;
  all)        show_dynamodb; show_rds; show_sqs ;;
  *)          die "Comando desconocido: $cmd (usa --help)" ;;
esac
