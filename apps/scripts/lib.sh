#!/usr/bin/env bash
# Funciones compartidas por los scripts de escenarios y evidencia.
# No se ejecuta directamente: los demas scripts hacen `source lib.sh`.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
INFRA="$ROOT/infra"
NAMESPACE="concertpass"

export AWS_PAGER=""
# Mismo kubeconfig aislado que usa infrastructure.py
export KUBECONFIG="${KUBECONFIG_OVERRIDE:-$INFRA/.generated/kubeconfig}"

log()  { printf '%s\n' "$*"; }
# Imprime el bloque de comentarios del encabezado de un script (para --help)
usage_from_header() { awk 'NR > 1 { if ($0 ~ /^#/) { sub(/^# ?/, ""); print } else exit }' "$1"; }
step() { printf '\n== %s ==\n' "$*"; }
warn() { printf 'AVISO: %s\n' "$*" >&2; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

need() {
  local c
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || die "Falta la herramienta: $c"
  done
}

# kubectl dentro del namespace de la aplicacion
k() { kubectl --namespace="$NAMESPACE" "$@"; }

# Lee un output de Terraform (solo strings)
tf_out() {
  terraform -chdir="$INFRA" output -raw "$1" 2>/dev/null \
    || die "No pude leer el output '$1' de Terraform. ¿Ya corriste setup.sh?"
}

# Solo letras, numeros, guion y guion bajo: los valores se usan dentro de SQL y JSON.
safe_ident() {
  [[ "$2" =~ ^[A-Za-z0-9_-]+$ ]] || die "Valor invalido para $1: '$2'"
}

# Carga la configuracion de la infraestructura y deja kubectl listo.
load_config() {
  need terraform aws kubectl curl
  REGION="$(tf_out region)"
  CLUSTER_NAME="$(tf_out cluster_name)"
  QUEUE_URL="$(tf_out queue_url)"
  EVENTS_TABLE="$(tf_out events_table)"
  export REGION CLUSTER_NAME QUEUE_URL EVENTS_TABLE
  if [ ! -f "$KUBECONFIG" ]; then
    mkdir -p "$(dirname "$KUBECONFIG")"
    aws --region "$REGION" eks update-kubeconfig --name "$CLUSTER_NAME" \
      --kubeconfig "$KUBECONFIG" >/dev/null
  fi
}

# Determina la URL de la API (NodePort 30080 en un nodo) y comprueba que responde.
# Se puede forzar con API_URL=http://host:puerto (por ejemplo con kubectl port-forward).
resolve_api_url() {
  if [ -z "${API_URL:-}" ]; then
    local ip
    ip="$(k get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="ExternalIP")].address}' 2>/dev/null || true)"
    [ -n "$ip" ] || die "Los nodos no tienen IP publica. Usa: kubectl -n $NAMESPACE port-forward svc/ticket-api 8080:80 y ejecuta con API_URL=http://localhost:8080"
    API_URL="http://$ip:30080"
  fi
  export API_URL
  curl -fsS --max-time 10 "$API_URL/openapi.json" >/dev/null \
    || die "La API no responde en $API_URL. Revisa que los pods esten Running y api_allowed_cidr (security group)."
  log "API: $API_URL"
}

# Ejecuta SQL contra RDS desde un pod de ticket-api (la base no es publica).
# Uso: db_query "SELECT ..."          -> tabla alineada
#      db_query "SELECT ..." scalar   -> solo el primer valor de la primera fila
db_query() {
  k exec -i deploy/ticket-api -- python - "$1" "${2:-table}" <<'PY'
import os, sys
import psycopg2

sql, mode = sys.argv[1], sys.argv[2]
conn = psycopg2.connect(
    host=os.environ["DB_HOST"], port=os.environ["DB_PORT"], dbname=os.environ["DB_NAME"],
    user=os.environ["DB_USER"], password=os.environ["DB_PASSWORD"],
    connect_timeout=10, sslmode="require",
)
with conn, conn.cursor() as cur:
    cur.execute(sql)
    if cur.description is None:
        print("OK (%d filas afectadas)" % cur.rowcount)
    else:
        rows = cur.fetchall()
        if mode == "scalar":
            print(rows[0][0] if rows else "")
        else:
            head = [d[0] for d in cur.description]
            data = [["" if v is None else str(v) for v in r] for r in rows]
            widths = [max([len(h)] + [len(r[i]) for r in data]) for i, h in enumerate(head)]
            fmt = " | ".join("%-" + str(w) + "s" for w in widths)
            print(fmt % tuple(head))
            print("-+-".join("-" * w for w in widths))
            for r in data:
                print(fmt % tuple(r))
            print("(%d filas)" % len(data))
PY
}

db_scalar() { db_query "$1" scalar; }

# Capacidad maxima de una seccion, leida de DynamoDB
dynamo_capacity() {
  local value
  value="$(aws --region "$REGION" dynamodb get-item --table-name "$EVENTS_TABLE" \
    --key "{\"concert_id\":{\"S\":\"$1\"}}" \
    --query "Item.capacity.M.\"$2\".N" --output text)"
  { [ -n "$value" ] && [ "$value" != "None" ]; } \
    || die "No existe capacidad para concierto '$1' y tipo '$2' en DynamoDB."
  printf '%s' "$value"
}

# Boletos ya vendidos (booked + confirmed) de un concierto/tipo
sold_count() {
  db_scalar "SELECT COALESCE(SUM(quantity), 0) FROM reservations WHERE concert_id = '$1' AND ticket_type = '$2' AND status IN ('booked', 'confirmed')"
}

# Estado actual de una reservacion segun GET /reservation/{id} (vacio si no hay respuesta valida)
status_of() {
  curl -sS --max-time 10 "$API_URL/reservation/$1" 2>/dev/null \
    | sed -n 's/.*"status" *: *"\([^"]*\)".*/\1/p' || true
}

# Convierte una lista de ids en  'id1','id2',...  para usar en un IN (...)
sql_id_list() {
  local out
  out="$(printf "'%s'," "$@")"
  printf '%s' "${out%,}"
}
