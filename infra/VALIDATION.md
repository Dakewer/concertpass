# Validación final: Terraform + eksctl — 29 de octubre de 2026

Se completó la migración conservando RDS, DynamoDB y SQS. Terraform ejecutó eksctl create cluster, que creó sus stacks internos CloudFormation, el clúster concertpass y exactamente dos nodos administrados. Esta arquitectura fue aceptada expresamente por el usuario para cumplir el punto 1.7. Terraform también publicó las imágenes ECR y aplicó los manifiestos de Kubernetes.

La última reconciliación terminó correctamente. El plan posterior devolvió código 0 y `No changes. Your infrastructure matches the configuration.`

## Resultados observados sobre el clúster nuevo

- Dos nodos Ready; dos réplicas del API y una de checkout. El worker vuelve a una réplica tras la carga.
- Tabla reservations con las ocho columnas requeridas, NOT NULL, clave primaria UUID e índice de inventario; acceso SSL desde pod.
- ConfigMap/Secret configurados desde Secrets Manager. SQS FIFO con DLQ y dos conciertos en DynamoDB, consultados desde pods.
- Las 15 comprobaciones HTTP de API/checkout pasaron, incluyendo cantidades e identificadores inválidos.
- La función final de inventario pasó cinco rondas de 30 reservas con tres conexiones simultáneas a RDS y capacidad fija 7: en cada ronda hubo 7 booked y 23 rejected. Las 150 filas aisladas se eliminaron. Esta prueba verifica la transacción; la capacidad se fija en el arnés para aislar el bloqueo.
- Se ejecutó `python apps/scripts/demo.py --reset --pause 2` con código de salida 0 y sus diez pasos PASS. Se observó el mensaje real con MessageGroupId=bad-bunny-gdl, pending en RDS y confirmed por GET.
- Nicho: cuatro reservas confirmed. Alta demanda: 60 solicitudes aceptadas, 50 confirmed y 10 rejected, tres workers, vendidos=50/capacidad=50. Checkout mostró respuestas HTTP 200. Al finalizar, cola principal y DLQ vacías.
- El SHA256 de main.py dentro de cada uno de los tres contenedores coincidió con el archivo local correspondiente.

La salida completa de la demostración está en [docs/EVIDENCIA_DEMO.txt](../docs/EVIDENCIA_DEMO.txt). El despliegue queda encendido para que el equipo pueda probarlo y grabar. **No se ejecutó teardown sobre este clúster nuevo**; la eliminación histórica descrita abajo corresponde al ciclo anterior. El teardown actualizado incluye eksctl delete cluster --wait y el verificador revisa también los stacks de eksctl y el security group compartido.

Los estados correctos son pending → booked → confirmed, o pending → rejected. PostgreSQL rechaza SUM(...) FOR UPDATE directamente sobre un agregado (SQLSTATE 0A000); la implementación bloquea filas en una subconsulta y suma fuera, además de serializar cada inventario mediante un bloqueo transaccional previo.

---

## Evidencia histórica de ciclos anteriores

# Validación real en AWS — 29 de octubre de 2026

Región: `us-east-1`. Se descargó `origin/main` (`211e574`) mediante `git fetch`; la rama local ya coincidía con ese commit. Los cambios locales previos se respaldaron en un stash y se restauraron después de probar la versión remota. No se hicieron commits ni push.

## Despliegue y resultados

Terraform encontró infraestructura parcial y completó nueve recursos sin cambios ni destrucciones. El plan posterior terminó con `No changes`. Se publicaron las tres imágenes remotas en ECR con tag `aws-20261029` y se desplegaron los tres servicios en EKS.

| Comprobación | Resultado observado |
| --- | --- |
| EKS | Exactamente dos nodos Ready, Kubernetes v1.35.9-eks-577a51e |
| Componentes del clúster | VPC CNI, CoreDNS y kube-proxy Running |
| RDS desde Kubernetes | Job completado por SSL; ocho columnas NOT NULL, UUID como clave primaria e índice de inventario |
| Secrets Manager | Configuración y secreto de base de datos inyectados en Kubernetes |
| SQS y DynamoDB desde un pod | FIFO=true; DLQ con maxReceiveCount=5; dos conciertos precargados |
| Deployments | Dos réplicas de API, una de checkout y una de worker disponibles, sin reinicios en la captura final |
| API público | Respuesta por NodePort 30080 |
| Demostración FIFO | Mensaje con MessageGroupId=bad-bunny-gdl, reserva pending en RDS y confirmed tras reactivar worker; cola vacía |
| Nicho, versión remota | Cuatro reservas de un boleto; todas confirmed |
| Alta demanda, versión remota | 60 solicitudes aceptadas, 50 confirmed y 10 rejected para capacidad VIP=50; tres workers; sin sobreventa |
| Redelivery | Reenvío de mensaje de una reserva confirmada; conserva confirmed |

## Fallos encontrados y correcciones locales comprobadas

La versión remota aceptó quantity=0 y quantity=-1 con HTTP 200; ambas reservas inválidas llegaron a confirmed. La evidencia final conserva esas dos filas bajo el concierto de prueba `validation-invalid-input`, cuya suma es -1. No forman parte de los escenarios de aforo. Checkout también aceptó un body vacío con HTTP 200.

Se restauraron las correcciones locales que ya existían antes de sincronizar: quantity entero estricto mayor que cero e identificadores no vacíos en API; body con UUID y cantidad positiva en checkout. Se publicaron y desplegaron API y checkout con tag `aws-20261029-validado`; worker conserva `aws-20261029`.

- Las 15 comprobaciones HTTP de la versión corregida pasaron: UUID inexistente devuelve 404; UUID inválido y body incompleto devuelven 422; cantidades cero, negativas, fraccionarias, booleanas o texto e identificadores vacíos devuelven 422. Checkout válido devuelve 200; body vacío, UUID inválido y cantidad cero devuelven 422.
- Se repitió nicho con tres reservas adicionales: todas confirmed.
- Se repitió alta demanda en floor: 110 solicitudes aceptadas sin errores HTTP, 100 confirmed y 10 rejected, capacidad=100, tres workers; sin sobreventa. El script restauró una réplica del worker.
- Se detuvo checkout y se observó una reserva booked y un error de conexión en el worker. Tras restaurarlo, la reserva se confirmó aproximadamente 120 segundos después de booked. La prueba inicial de 100 segundos falló; el seguimiento confirmó la recuperación eventual. No se afirma recuperación dentro de 100 segundos.
- Se restauraron también las comprobaciones de los scripts: exigir confirmed en la demostración SQS y fallar si la verificación de eliminación contiene resultados desconocidos.

Estas pruebas demuestran los escenarios ejecutados. No constituyen una prueba exhaustiva de concurrencia de las transacciones fuera de la serialización FIFO, ni de recuperación ante un cierre entre el commit de RDS y el envío a SQS.

## Evidencia local

Las salidas de consola se guardaron en `infra/.generated/evidence-20261029/`: nodos, esquema, acceso AWS desde pod, FIFO, ambas versiones de los escenarios, comprobaciones HTTP, fallo y recuperación de checkout, estado final de datos, Deployments y plan de Terraform. Esta carpeta está ignorada por Git y no se publica automáticamente.

## Eliminación comprobada de esta ejecución

El usuario solicitó expresamente eliminar al terminar. Se ejecutó `bash apps/scripts/teardown.sh --auto-approve`: Terraform terminó con `Destroy complete! Resources: 21 destroyed.`, dejó su estado vacío y eliminó el kubeconfig temporal.

Después se ejecutó `bash apps/scripts/verify-teardown.sh`. Todas las comprobaciones terminaron OK, sin resultados desconocidos, con código de salida 0 y `PASS: no queda ningun recurso del stack.` AWS CLI confirmó la ausencia de EKS, instancias activas de los nodos, launch template, security groups del clúster y RDS, instancia RDS, ambas colas SQS, DynamoDB, secreto y los tres repositorios ECR. Las salidas están en `teardown.txt` y `verify-teardown.txt` dentro de la carpeta de evidencia. La VPC y LabRole preexistentes se conservaron.

---

## Validación histórica del 22 de octubre

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
