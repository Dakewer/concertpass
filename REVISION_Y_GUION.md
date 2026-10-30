> Nota histórica anterior a la migración final. La configuración vigente y sus pruebas están en README.md e infra/VALIDATION.md.

# Revisión de main remoto y guía del video — 29 de octubre de 2026

## Versión obtenida y límites

Se descargó origin/main en el commit 211e574 y se extrajeron sus 36 archivos sobre la copia local. La comparación contra los blobs remotos no encontró diferencias al normalizar finales de línea CRLF/LF. Git no pudo actualizar HEAD ni el índice porque no permite crear .git/index.lock; por eso git status compara todavía con el commit local anterior. No ejecutar commits sobre ese índice sin resolver primero ese permiso.

AWS CLI no puede conectar con el proxy configurado http://127.0.0.1:9. No se verificaron credenciales, recursos actuales ni funcionamiento en la nube. No se desplegó ni se destruyó infraestructura en esta sesión. infra/VALIDATION.md es evidencia histórica y no sustituye una validación actual de los tres servicios.

## Hallazgos de la versión remota

- Ya existen los tres servicios con Dockerfiles, los dos endpoints del API, envío FIFO con MessageGroupId por concierto y deduplicación por reserva, consumidor, consulta de capacidad, llamada a checkout y actualización de estados.
- Ya existen scripts de evidencia, escenarios de baja y alta demanda, escalamiento temporal a tres workers, teardown y verificación posterior. También existe docs/Reporte_Concertpass.pdf; no se verificaron visualmente su contenido ni sus dos páginas máximas.
- Terraform configura dos nodos, RDS privado, dos eventos DynamoDB, SQS FIFO y DLQ, ECR y Secrets Manager. Esto describe código, no el estado actual de AWS.
- El API permite quantity cero o negativa. Una cantidad negativa puede disminuir el total vendido y permitir sobreventa posterior: debe validarse como entero estrictamente positivo. También faltan límites para identificadores vacíos.
- Checkout responde éxito pero no define ni valida el body solicitado por la práctica.
- El API confirma el INSERT antes de enviar a SQS y borra la reserva ante un error del cliente AWS. Un timeout ambiguo puede ocurrir después de que SQS haya recibido el mensaje; ese borrado puede competir con el worker. Un cierre del proceso entre commit y envío deja reservas pendientes sin mensaje. Hace falta una estrategia de recuperación para tolerar estos fallos.
- El worker usa FOR UPDATE en una subconsulta y suma fuera de ella, evitando el agregado bloqueado inválido de la consigna. Su seguridad con lecturas concurrentes e inserciones nuevas requiere una prueba transaccional real; no basta con que la sintaxis sea válida. El timeout de visibilidad fijo y el procesamiento de lotes también requieren probar redelivery e idempotencia.
- verify-teardown.sh termina con código de éxito cuando hay comprobaciones desconocidas y no detecta recursos existentes. Debe fallar también si UNKNOWN es mayor que cero para que automatización no confunda falta de conectividad con eliminación comprobada.
- evidence.sh sqs-demo puede terminar con éxito aunque venza el plazo sin estado final; debe comprobar y exigir confirmed para la reserva demostrada.
- La consigna pide eksctl literalmente y el proyecto utiliza Terraform. La equivalencia técnica no garantiza cumplimiento de ese punto académico.
- La sintaxis de los cuatro archivos Python se verificó mediante ast.parse. Las pruebas de integración y carga permanecen pendientes por falta de acceso a AWS.

## Validación pendiente

Con acceso efectivo a AWS y Docker: ejecutar setup, publicar las tres imágenes con tag único, desplegar, validar dos nodos Ready, ejecutar evidencia SQS, escenario de nicho, alta demanda con tres workers y consultas de estado y cantidades. Probar entradas inválidas, UUID inexistente, redelivery, fallos de checkout y envío SQS. Después capturar evidencia y ejecutar teardown y verificación de eliminación. No presentar la ausencia de recursos como comprobada si hay errores de permisos, red o credenciales.

## Qué hace EKS en este proyecto

El clúster ejecuta y coordina los contenedores de los microservicios. Mantiene el número configurado de réplicas, reemplaza pods fallidos, permite actualizar imágenes y proporciona comunicación interna. La protección contra sobreventa depende de la aplicación y sus transacciones; aumentar réplicas no garantiza consistencia por sí mismo.

| Componente configurado o propio de Kubernetes | Función |
| --- | --- |
| Plano de control administrado por EKS | API de Kubernetes, planificación y control del estado deseado. AWS administra este plano. |
| Dos nodos EC2 del grupo administrado | Aportan CPU y memoria para ejecutar pods. No son lo mismo que los workers de boletos. |
| Pods y Deployments | Los manifiestos solicitan dos réplicas del API, una de checkout y una del worker. El worker de boletos es un proceso consumidor dentro de un pod. |
| NodePort del API | Expone el API por el puerto 30080 de los nodos, sujeto a conectividad y reglas de red. |
| ClusterIP de checkout | Ofrece una dirección interna estable para llamadas desde el worker. |
| CoreDNS | Resuelve nombres internos, por ejemplo `ticket-checkout.concertpass.svc.cluster.local`. |
| VPC CNI | Conecta los pods a la red de AWS. |
| kube-proxy | Implementa el encaminamiento de Services hacia pods. |
| Namespace concertpass | Agrupa los recursos de la aplicación. |
| ConfigMap y Secret | Entregan configuración y credenciales mediante variables de entorno. Secrets Manager guarda el secreto original fuera de Kubernetes. |
| ServiceAccounts y rol de nodo | Existen cuentas por servicio, pero no hay roles IAM separados por pod: se usa LabRole mediante IMDSv2 del nodo. Es una decisión de laboratorio con permisos compartidos. |
| Probes y límites | Los servicios HTTP tienen probes TCP y límites de recursos; el worker no tiene probes. Un puerto abierto no demuestra que el flujo de negocio funcione. |
| Job de esquema y Job de validación | Crean/verifican la tabla y comprueban acceso a servicios AWS. No reemplazan pruebas funcionales. |

RDS, DynamoDB, SQS, Secrets Manager y ECR son servicios externos al clúster. ECR almacena imágenes; los nodos las descargan para ejecutar contenedores. RDS persiste reservas, DynamoDB conserva la definición de eventos y SQS desacopla recepción y procesamiento. El grupo de nodos está fijado en dos; escalar pods requiere capacidad disponible y no existe autoscaling de aplicación configurado.

Referencia de EKS: https://docs.aws.amazon.com/eks/latest/userguide/what-is-eks.html

## Guion conceptual para el video

Este guion describe el flujo implementado en el código remoto; presentarlo como funcionamiento demostrado únicamente después de validarlo en AWS.

“Concertpass es un sistema de reservación de boletos para conciertos. Busca recibir muchas solicitudes y asignar boletos sin superar la capacidad disponible de cada sección. Está organizado en tres microservicios: ticket-api recibe solicitudes y permite consultar su estado; ticket-worker procesa las reservaciones y revisa el inventario; ticket-checkout simula la autorización del pago.

Cuando llega una solicitud, el API registra una reserva pendiente en PostgreSQL y publica un mensaje en SQS FIFO. El identificador del concierto se usa como grupo del mensaje para mantener el orden de procesamiento de cada concierto. El worker consulta la capacidad definida en DynamoDB y calcula lo vendido en PostgreSQL dentro de una transacción protegida. Si hay espacio, aparta los boletos, llama a checkout y confirma la reservación cuando recibe autorización. Si no hay espacio, la rechaza.

Los contenedores se ejecutan en Kubernetes mediante Amazon EKS, sobre dos nodos EC2. Kubernetes mantiene las réplicas y la comunicación entre servicios. Las imágenes se almacenan en ECR y las credenciales de la base de datos se guardan en Secrets Manager.

La demostración incluye un caso de baja demanda con reservas exitosas y otro con más solicitudes que boletos. Al aumentar a tres workers, debemos demostrar que las transacciones siguen evitando la sobreventa. Al terminar eliminamos la infraestructura para evitar cargos.”

## Orden de demostración de 5–10 minutos

1. Explicar el objetivo y mostrar el diagrama del README.
2. Mostrar `kubectl get nodes` y `kubectl -n concertpass get pods,services`; explicar la diferencia entre nodos y pods.
3. Mostrar los dos conciertos en DynamoDB y la tabla de reservas en RDS.
4. Demostrar una reserva pendiente, el envío a SQS y la consulta de estado hasta confirmación. Coordinar la captura del mensaje sin que una lectura manual interfiera con el consumidor.
5. Ejecutar 3–5 reservas exitosas del escenario de nicho.
6. Escalar temporalmente el worker a tres réplicas y enviar solicitudes por encima del aforo de una sección. Mostrar `confirmed`, `rejected` y la suma de cantidades vendidas en RDS.
7. Explicar el bloqueo y el costo en concurrencia: las decisiones sobre el mismo inventario se serializan para conservar consistencia.
8. Ejecutar `bash apps/scripts/teardown.sh` y mostrar la confirmación de eliminación, junto con consultas de AWS. Esta eliminación debe realizarse después de capturar toda la evidencia requerida.
