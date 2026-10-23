# Validacion de infraestructura en AWS

Fecha: 22 de octubre de 2026. Region: `us-east-1`.

Se ejecuto un ciclo real de provisionamiento y comprobacion, con eliminacion al terminar solicitada por el usuario. El codigo de los servicios se restauro al commit `772880f`; estos resultados describen infraestructura y despliegue.

| Comprobacion | Resultado observado |
| --- | --- |
| Terraform apply | 21 recursos creados |
| Cluster EKS | Dos nodos `Ready`, Kubernetes `v1.35.9-eks-117f323` |
| Addons | VPC CNI, CoreDNS y kube-proxy ejecutandose |
| RDS desde un pod | Job completado por SSL; PostgreSQL creo la tabla `reservations` y el indice de inventario |
| Esquema SQL | Ocho columnas requeridas, clave primaria UUID y campos NOT NULL |
| Secrets Manager | Credenciales inyectadas en un Secret Kubernetes; reconfiguracion comprobada |
| SQS desde un pod | `FifoQueue=true`, DLQ configurada y `maxReceiveCount=5` |
| DynamoDB desde un pod | Dos conciertos y capacidades por seccion legibles |
| ECR | Tres repositorios creados; imagenes de API y checkout publicadas |
| Deployments existentes | Dos replicas API y una de checkout, listas y sin reinicios |
| NodePort | `/openapi.json` respondio HTTP 200 por el puerto 30080 de ambos nodos |
| Servicio interno | Checkout respondio HTTP 200 desde un pod del API usando DNS Kubernetes |
| Manifiesto del worker | Validado con dry-run del servidor; no se desplego una imagen porque el servicio no existe en este commit |
| Estado Terraform | Plan posterior: `No changes. Your infrastructure matches the configuration.` |
| Archivos | Sintaxis Bash y Python verificadas; `git diff` de ambos servicios sin cambios |

## Eliminacion comprobada

Se ejecuto `python apps/scripts/infrastructure.py teardown --auto-approve`. Terraform termino con `Destroy complete! Resources: 21 destroyed.`, su estado quedo vacio y el kubeconfig temporal se elimino.

Las consultas posteriores con AWS CLI confirmaron que no quedan el cluster EKS, la instancia RDS, los repositorios ECR, las colas SQS, la tabla DynamoDB ni el secreto del stack. Ambas instancias EC2 quedaron en estado `terminated`; tampoco quedaron los security groups del cluster/base de datos ni el launch template. La VPC y los roles preexistentes no forman parte de los recursos administrados por este stack.

Las credenciales AWS de los pods proceden del rol existente `LabRole` mediante IMDSv2. No se crearon roles IAM ni se agregaron llaves AWS a imagenes, manifiestos o archivos de codigo. Los valores de Secrets Manager no se imprimieron en los comandos de validacion.
