# Concertpass

Sistema de reservación de boletos desplegado en AWS EKS. El API guarda reservas pending en RDS PostgreSQL y publica mensajes SQS FIFO con MessageGroupId=concert_id. El worker consulta la capacidad en DynamoDB y aparta o rechaza boletos en una transacción. Checkout simula autorizar el pago; el worker actualiza a confirmed.

Estados: pending → booked → confirmed, o pending → rejected.

## Infraestructura

Terraform es el punto de entrada de todo el despliegue. Crea RDS, Secrets Manager, DynamoDB con dos conciertos, SQS FIFO con DLQ y tres repositorios ECR. Para cumplir el uso de eksctl requerido por la práctica, Terraform ejecuta eksctl para crear EKS y un grupo administrado de exactamente dos nodos. **eksctl usa CloudFormation internamente**; sus stacks se crean y eliminan dentro del ciclo de Terraform.

Se reutilizan LabRole y la VPC predeterminada de AWS Academy. No se crean roles IAM. Las aplicaciones reciben configuración mediante ConfigMap y Secret; las credenciales de RDS proceden de Secrets Manager. DynamoDB es de solo lectura para el código de los servicios.

Terraform también construye y publica las imágenes Docker, aplica los manifiestos con kubectl, inicializa la tabla reservations y valida el acceso desde pods a AWS. Los servicios se ejecutan en AWS; Python, Terraform, Docker y kubectl son herramientas de despliegue en el equipo del operador.

## Requisitos

AWS CLI con credenciales vigentes del laboratorio, Terraform >=1.5, Python >=3.9, kubectl y Docker con motor Linux activo. Para la demostración se necesita Bash (Git Bash en Windows). Si eksctl no está instalado, el adaptador descarga la versión fijada y verifica su SHA256 oficial.

## Desplegar

Desde la raíz:

```powershell
aws sts get-caller-identity
python apps/scripts/infrastructure.py setup --auto-approve
```

También se puede ejecutar `bash apps/scripts/setup.sh --auto-approve`, o directamente:

```powershell
terraform -chdir=infra init
terraform -chdir=infra apply
```

El primer despliegue puede tardar varios minutos. No ejecutes dos apply simultáneamente. El kubeconfig aislado se guarda en infra/.generated/kubeconfig. Estado, planes, kubeconfig y archivos generados están ignorados por Git porque pueden contener información sensible.

## Demostración con un comando

```powershell
python apps/scripts/demo.py --reset --pause 3
```

**--reset borra todas las reservas y purga las dos colas.** Úsalo para comenzar una demostración desde cero. El script espera 60 segundos tras purgar SQS, muestra las operaciones, hace pausas entre pasos y termina con un resumen PASS/FAIL y código de salida distinto de cero ante un fallo. No elimina la infraestructura al terminar.

Comprueba dos nodos Ready, acceso AWS desde pods, un mensaje real en SQS, pending en RDS y confirmed por GET; después ejecuta cuatro reservas de nicho y 60 solicitudes VIP con tres workers. En una corrida limpia se esperan cuatro confirmed en nicho y 50 confirmed/10 rejected en alta demanda, sin sobreventa. El worker vuelve a una réplica. Se muestran las reservas y capacidades en RDS y DynamoDB y los conteos de SQS/DLQ.

Los conciertos iniciales son artista-nicho-cdmx (general=8, vip=3, floor=4) y bad-bunny-gdl (general=500, vip=50, floor=100). Cada POST crea una reserva nueva y afecta la disponibilidad cuando se confirma.

## Prueba manual

```powershell
$env:KUBECONFIG = "$PWD/infra/.generated/kubeconfig"
kubectl get nodes -o wide
kubectl -n concertpass get pods,services
```

Abre http://IP_PUBLICA_DE_UN_NODO:30080/docs para Swagger UI. POST /reserve recibe:

```json
{"concert_id":"bad-bunny-gdl","user_id":"usr_123","ticket_type":"vip","quantity":2}
```

Copia reservation_id y consulta GET /reservation/{reservation_id} hasta confirmed o rejected. Cantidades no positivas o identificadores vacíos devuelven 422. La raíz / puede responder 404; la interfaz de pruebas está en /docs. Checkout es interno, recibe reservation_id UUID y quantity positiva y responde 200 autorizando el pago simulado.

## Consistencia

El worker usa un bloqueo transaccional por concierto/sección y SELECT FOR UPDATE sobre filas antes de sumar booked y confirmed. El bloqueo por inventario se toma en una sentencia separada para que la consulta posterior vea un snapshot actualizado. Cuando no hay espacio, hace rollback y actualiza únicamente la reserva rechazada en otra transacción. Los mensajes repetidos revisan el estado para retomar booked o ignorar estados finales.

La consulta literal SUM(...) FOR UPDATE del enunciado no es válida en PostgreSQL: el proyecto bloquea filas en una subconsulta y suma fuera de ella. El costo de conservar consistencia es serializar las decisiones sobre un mismo inventario. FIFO mantiene el orden por concierto; diferentes conciertos pueden progresar en paralelo.

## Eliminar al terminar

```powershell
python apps/scripts/infrastructure.py teardown --auto-approve
```

Equivalente Bash: `bash apps/scripts/teardown.sh --auto-approve`. El teardown elimina el namespace y Terraform destruye los recursos, invocando eksctl delete cluster --wait para el clúster y sus stacks. Conserva la VPC y los roles preexistentes. Después ejecuta:

```bash
bash apps/scripts/verify-teardown.sh
```

Debe terminar PASS sin resultados desconocidos. La eliminación borra los datos, mensajes e imágenes del proyecto. EKS, nodos y RDS generan cargos mientras existan.

## Estructura

Servicios y Dockerfiles: apps/ticket-api, apps/ticket-worker y apps/ticket-checkout. Scripts: apps/scripts, como exige la sección 1.10. Manifiestos: k8s. Terraform: infra. Este layout mantiene las rutas existentes del equipo; difiere del árbol ilustrativo del enunciado que sitúa servicios y scripts en la raíz.

Resultados históricos: [infra/VALIDATION.md](infra/VALIDATION.md). No sustituyen la salida de una demostración sobre el despliegue actual. Reporte y video son entregables preparados por el equipo.
