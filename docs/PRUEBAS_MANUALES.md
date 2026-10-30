# CÃ³mo probar Concertpass

Concertpass ofrece Swagger UI, la interfaz interactiva del API. No incluye una pÃ¡gina de compra para clientes. Los tres microservicios se ejecutan en AWS EKS; desde el navegador se accede al API mediante el NodePort 30080.

## DirecciÃ³n del despliegue

Despliegue disponible para pruebas: [http://52.72.201.182:30080/docs](http://52.72.201.182:30080/docs), [http://100.53.230.87:30080/docs](http://100.53.230.87:30080/docs). Las IP pueden cambiar al recrear la infraestructura. La comprobaciÃ³n inicial creÃ³ una reserva confirmada de un boleto general y una rechazada de 501; nicho y VIP no se usaron.

## Crear y consultar una reserva desde el navegador

1. Abre `http://IP_PUBLICA:30080/docs`.
2. Expande **POST /reserve**, pulsa **Try it out** y reemplaza el ejemplo por:

   ```json
   {
     "concert_id": "bad-bunny-gdl",
     "user_id": "usr_emmanuel_01",
     "ticket_type": "general",
     "quantity": 1
   }
   ```

3. Pulsa **Execute**. Debes recibir HTTP 200 y un `reservation_id`. El POST responde con `pending`; el worker procesa la reserva en segundo plano.
4. Copia el identificador, expande **GET /reservation/{reservation_id}**, pulsa **Try it out**, pÃ©galo y pulsa **Execute**.
5. Vuelve a ejecutar la consulta si aÃºn aparece `pending` o `booked`. Con capacidad disponible debe terminar en `confirmed`. La confirmaciÃ³n usa un pago simulado; no se necesitan tarjetas.

Cada ejecuciÃ³n de POST crea una reserva nueva y consume capacidad cuando se confirma. Repetir GET solamente consulta. Ver HTTP 404 al abrir la raÃ­z `/` no implica que el servicio estÃ© caÃ­do: usa `/docs`.

## Resultados que puedes comprobar

- **Reserva confirmada:** usa el ejemplo anterior con cantidad 1 y consulta su identificador.
- **Sin capacidad:** solicita 501 boletos de `bad-bunny-gdl`, tipo `general`, en una sola reserva. El API recibe la solicitud con HTTP 200; al procesarla, el worker debe dejarla en `rejected`, porque esa secciÃ³n tiene capacidad total 500.
- **Cantidad invÃ¡lida:** envÃ­a cantidad 0 o -1. El API debe responder HTTP 422 y no crear una reserva.
- **Reserva inexistente:** consulta `00000000-0000-0000-0000-000000000000`. Debe responder HTTP 404.

Capacidades iniciales en DynamoDB:

| concert_id | floor | vip | general |
| --- | ---: | ---: | ---: |
| bad-bunny-gdl | 100 | 50 | 500 |
| artista-nicho-cdmx | 4 | 3 | 8 |

## Pruebas automÃ¡ticas y evidencia

Desde la raÃ­z del repositorio, en PowerShell:

```powershell
$env:KUBECONFIG = "$PWD/infra/.generated/kubeconfig"
kubectl get nodes
kubectl -n concertpass get pods,services
kubectl -n concertpass logs deployment/ticket-worker --tail=30
```

Desde Git Bash, tambiÃ©n en la raÃ­z:

```bash
bash apps/scripts/scenario-niche.sh
bash apps/scripts/scenario-high-demand.sh
bash apps/scripts/evidence.sh all
```

El escenario de nicho crea cuatro reservas. El de alta demanda envÃ­a 60 solicitudes VIP para una capacidad de 50, escala temporalmente el worker a tres rÃ©plicas y lo restaura a una al terminar. Estos resultados dependen de la capacidad que todavÃ­a quede; las reservas anteriores permanecen en la base de datos.

Para demostrar el mensaje y su MessageGroupId en SQS:

```bash
bash apps/scripts/evidence.sh sqs-demo
```

Este script detiene temporalmente el worker, crea una reserva, muestra el mensaje y vuelve a activar el worker. Evita ejecutarlo mientras otra persona hace pruebas.

Si necesitas repetir todo desde cero, este comando **borra todas las reservas y purga las dos colas**:

```bash
bash apps/scripts/evidence.sh reset --yes
```

Tras purgar SQS, espera al menos 60 segundos antes de crear nuevas reservas, para que la purga no alcance mensajes reciÃ©n enviados.

## Apagar al terminar

La infraestructura permanece encendida para las pruebas y genera cargos mientras existe. Desde PowerShell:

```powershell
python apps/scripts/infrastructure.py teardown
```

Terraform solicita confirmaciÃ³n antes de borrar los recursos y sus datos. DespuÃ©s, desde Git Bash:

```bash
bash apps/scripts/verify-teardown.sh
```

El resultado esperado es `PASS: no queda ningun recurso del stack.`
