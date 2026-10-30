#!/usr/bin/env bash
# Verifica con la AWS CLI que teardown.sh elimino los recursos del stack.
# No necesita Terraform ni kubeconfig (ya no existen): usa los nombres fijos de infra/main.tf.
#
# Uso: verify-teardown.sh [region]      (por defecto AWS_REGION o us-east-1)
set -euo pipefail
export AWS_PAGER=""

REGION="${1:-${AWS_REGION:-${AWS_DEFAULT_REGION:-us-east-1}}}"
CLUSTER="${CLUSTER_NAME:-concertpass}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA="$(cd "$SCRIPT_DIR/../.." && pwd)/infra"

command -v aws >/dev/null 2>&1 || { echo "ERROR: falta la herramienta aws" >&2; exit 1; }

FAILED=0
UNKNOWN=0
aws_() { aws --region "$REGION" "$@"; }

# check_gone <etiqueta> <regex de "no existe"> <comando...>
# Exito del comando = el recurso sigue existiendo. Error con el mensaje esperado = eliminado.
check_gone() {
  local label="$1" pattern="$2" out
  shift 2
  if out="$("$@" 2>&1)"; then
    printf '  [X]  %-34s SIGUE EXISTIENDO\n' "$label"
    FAILED=$((FAILED + 1))
  elif printf '%s' "$out" | grep -Eqi "$pattern"; then
    printf '  [OK] %-34s eliminado\n' "$label"
  else
    printf '  [?]  %-34s no se pudo comprobar: %s\n' "$label" "$(printf '%s' "$out" | head -n 1)"
    UNKNOWN=$((UNKNOWN + 1))
  fi
}

# check_empty <etiqueta> <comando...>  -> la salida debe estar vacia
check_empty() {
  local label="$1" out
  shift
  if ! out="$("$@" 2>&1)"; then
    printf '  [?]  %-34s no se pudo comprobar: %s\n' "$label" "$(printf '%s' "$out" | head -n 1)"
    UNKNOWN=$((UNKNOWN + 1))
  elif [ -z "$(printf '%s' "$out" | tr -d '[:space:]')" ] || [ "$out" = "None" ]; then
    printf '  [OK] %-34s ninguno\n' "$label"
  else
    printf '  [X]  %-34s QUEDAN: %s\n' "$label" "$out"
    FAILED=$((FAILED + 1))
  fi
}

echo "Verificando eliminacion de recursos en $REGION"
echo

echo "Computo y red"
check_gone  "Cluster EKS ($CLUSTER)"        'ResourceNotFoundException|No cluster found' aws_ eks describe-cluster --name "$CLUSTER"
check_empty "Instancias EC2 de los nodos" aws_ ec2 describe-instances \
  --filters "Name=tag:eks:cluster-name,Values=$CLUSTER" \
            "Name=instance-state-name,Values=pending,running,stopping,shutting-down,stopped" \
  --query 'Reservations[].Instances[].InstanceId' --output text
check_empty "Launch template de los nodos"  aws_ ec2 describe-launch-templates \
  --filters "Name=launch-template-name,Values=concertpass-nodes-*" \
  --query 'LaunchTemplates[].LaunchTemplateName' --output text
check_empty "Security group de la base"     aws_ ec2 describe-security-groups \
  --filters "Name=group-name,Values=concertpass-db-*" \
  --query 'SecurityGroups[].GroupId' --output text
check_empty "Security group del cluster"    aws_ ec2 describe-security-groups \
  --filters "Name=group-name,Values=eks-cluster-sg-$CLUSTER-*" \
  --query 'SecurityGroups[].GroupId' --output text

echo
check_empty "Security group compartido nodos" aws_ ec2 describe-security-groups \
  --filters "Name=group-name,Values=concertpass-nodes-*" \
  --query 'SecurityGroups[].GroupId' --output text
check_empty "Stacks activos de eksctl" aws_ cloudformation list-stacks \
  --query "StackSummaries[?starts_with(StackName, 'eksctl-$CLUSTER-') && StackStatus!='DELETE_COMPLETE'].StackName" --output text

echo "Datos y mensajeria"
check_gone "RDS concertpass-db"             'DBInstanceNotFound' aws_ rds describe-db-instances --db-instance-identifier concertpass-db
check_gone "SQS concertpass-reservations"   'NonExistentQueue|does not exist' aws_ sqs get-queue-url --queue-name concertpass-reservations.fifo
check_gone "SQS DLQ"                        'NonExistentQueue|does not exist' aws_ sqs get-queue-url --queue-name concertpass-reservations-dlq.fifo
check_gone "DynamoDB concert-events"        'ResourceNotFoundException|not found' aws_ dynamodb describe-table --table-name concert-events
check_gone "Secreto concertpass/database"   'ResourceNotFoundException|not found' aws_ secretsmanager describe-secret --secret-id concertpass/database

echo
echo "Imagenes"
for repo in ticket-api ticket-worker ticket-checkout; do
  check_gone "ECR concertpass/$repo" 'RepositoryNotFoundException' aws_ ecr describe-repositories --repository-names "concertpass/$repo"
done

if command -v terraform >/dev/null 2>&1 && [ -d "$INFRA" ]; then
  echo
  echo "Terraform"
  check_empty "Recursos en el estado de Terraform" terraform -chdir="$INFRA" state list
fi

echo
if [ "$FAILED" -eq 0 ] && [ "$UNKNOWN" -eq 0 ]; then
  echo "PASS: no queda ningun recurso del stack."
elif [ "$FAILED" -eq 0 ]; then
  echo "Sin recursos detectados, pero $UNKNOWN comprobaciones no pudieron confirmarse (revisa los [?])."
  exit 1
else
  echo "FAIL: $FAILED recurso(s) siguen existiendo."
  exit 1
fi
