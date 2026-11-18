# TO-DO: completa el worker

En esta versión del proyecto el sistema está casi completo: la infraestructura, el API, el
dashboard, las tiendas, la plantilla de arranque del worker y su pipeline ya existen. **Faltan
dos cosas, y las escribes tú:**

| Qué | Dónde |
|---|---|
| 1. El código del worker: lee los lotes de la cola de RabbitMQ y los guarda en MySQL | `central-worker/worker.py` y `central-worker/models.py` |
| 2. La máquina del worker y los valores que Terraform le pasa a su plantilla de arranque | `infraestructura/compute.tf` (bloque `aws_instance.worker`, comentado), `infraestructura/outputs.tf` y `Makefile` (busca el comentario `EJERCICIO`) |

**Puedes desplegar desde el primer día.** El bloque del worker está comentado en
`compute.tf`, en `outputs.tf` y en el `make up` del `Makefile`. Así, `make up` crea todo lo
demás: el API, el dashboard y las tiendas. Las compras llegan hasta la cola de RabbitMQ y se
quedan ahí, porque nadie las lee todavía. Compruébalo con los pasos 1 a 4 de
`GUIA-DE-PRUEBA.pdf`: la cola muestra mensajes en espera y 0 consumidores.

Después activas tu worker y compruebas con **`GUIA-DE-PRUEBA.pdf`** que una compra llega desde
la caja hasta MySQL en AWS y el dashboard.

> `TODO.md` (sin guion) es de un ejercicio anterior que ya está implementado en el código.
> Ignóralo. El ejercicio de ahora es **este** archivo.

---

## 1. Antes de empezar

- Trabaja dentro del contenedor `aws_dev_environment`, desde la carpeta de este proyecto.
- Una sesión activa del **AWS Academy Learner Lab** y sus credenciales en `~/.aws/credentials`
  dentro del contenedor (caducan: si pasaron unas horas, cópialas otra vez).
- `cp .env.example .env`.
- Lee:
  - `DEPLOY.md`: los pipelines, su orden y los comandos `make`.
  - `infraestructura/HOW-IT-WORKS.md`: sección **3** (qué es una plantilla `.tftpl` y qué
    significa `${...}`) y sección **5** (qué hace la máquina con el script).

---

## 2. Parte 1: el código del worker

Escribe `central-worker/worker.py` y `central-worker/models.py`. El `Dockerfile` y
`requirements.txt` ya están listos y no necesitas cambiarlos: la imagen copia esos dos archivos
y arranca con `python worker.py`.

Datos que ya tienes en el proyecto:

- **El contenedor recibe tres variables de entorno:** `CENTRAL_DATABASE_URL`, `RABBITMQ_URL` e
  `INGESTION_QUEUE`.
- **Lo que llega a la cola:** cada mensaje es un lote serializado por el API. Míralo en
  `central-api/app/ingestion/` (`service.py`, `publisher.py` y `schemas.py`).
- **Las tablas donde se guarda:** `central-db/01-schema.sql`.

**Pruébalo primero en tu computador.** `make up-local` levanta todo el sistema localmente,
incluido tu worker. Haz una compra en http://localhost:8081 y sigue el log con
`make logs CONTAINER=central-worker`. Cuando la venta aparezca en el dashboard local
(http://localhost:8080), pasa a AWS. Antes de seguir, apaga lo local con `make down`.

---

## 3. Parte 2: la máquina del worker en `compute.tf`

Activa el worker en tres sitios (cada uno tiene un comentario `EJERCICIO`):

1. `infraestructura/compute.tf`: quita el `# ` del inicio de cada línea del bloque
   `aws_instance.worker`.
2. `infraestructura/outputs.tf`: descomenta la línea `worker = aws_instance.worker.public_ip`.
3. `Makefile`: en el objetivo `up`, descomenta la línea `$(MAKE) deploy-worker`.

Ahora completa el mapa de la plantilla. La plantilla `infraestructura/templates/worker.sh.tftpl` ya está escrita. Ábrela: cada
`${nombre}` es un hueco que Terraform llena con el valor de `nombre` en el mapa que recibe
`templatefile()`. En `compute.tf` ese mapa está vacío. Complétalo:

- Debe tener **una entrada por cada `${...}` distinto** de la plantilla, con el mismo nombre.
- Los valores ya existen en el proyecto. Unos son variables (`variables.tf`), otros son
  atributos de las máquinas definidas más arriba en `compute.tf`, y otros son `locals` de ese
  mismo archivo.
- **Guíate por lo que ya está escrito:** la launch template del API en `scaling.tf` le pasa a
  su plantilla casi los mismos valores.
- Cada línea que escribas lleva su comentario.

Mientras el mapa esté incompleto, Terraform te dirá qué falta. Por ejemplo:

```
Invalid value for "vars" parameter: vars map does not contain key "common",
referenced at ./templates/worker.sh.tftpl:2,3-9.
```

Valida desde `infraestructura/`:

```bash
terraform init -backend=false   # solo la primera vez
terraform fmt                   # deja el formato ordenado
./check-comments.sh             # debe decir: OK: todas las líneas de código tienen comentario
terraform validate              # debe decir: Success! The configuration is valid
```

---

## 4. Despliega y prueba

Desde la raíz del proyecto:

```bash
make up
```

Si ya habías desplegado sin el worker, `make up` solo agrega la máquina del worker y despliega
tu código. Los lotes que esperaban en la cola se guardan apenas tu worker arranca. Si es la
primera vez, tarda unos 15 a 20 minutos. Corre, en orden, la infraestructura, el API, **tu worker**, el
dashboard y las tiendas. Si un paso falla, `make up` se detiene ahí. Lee el mensaje de la
etapa que falló (`==> [etapa]`). En `DEPLOY.md` está qué hace cada etapa.

Luego sigue **`GUIA-DE-PRUEBA.pdf`** con tu propia compra, paso a paso:

1. La compra en la caja.
2. La venta en PostgreSQL de la tienda: primero con `forwarded_at` vacío y luego con fecha.
3. El lote enviado con `202 Accepted`.
4. La cola con 0 mensajes y 1 consumidor, y el log de **tu** worker guardando el lote.
5. La factura en `invoices` y cada artículo en `invoice_items` de MySQL en AWS.
6. La venta en el dashboard.

Si tu compra se ve igual en cada paso, el worker funciona.

---

## 5. Recomendaciones

- **Si algo falla en AWS, el log manda.** En la máquina del worker:
  `/var/log/central-bootstrap.log` (el arranque; termina en `bootstrap finished OK`),
  `/var/log/central-update.log` (cada despliegue) y `sudo docker logs central-worker` (tu
  código).
- **El arranque se queda en `esperando a ...:3306`.** La máquina no llega a MySQL: revisa la IP
  que pusiste en el mapa.
- **El pipeline del worker falla en `verify`.** Tu contenedor se cae o se reinicia: mira
  `sudo docker logs central-worker`. Corrige el código, pruébalo con `make up-local` y vuelve
  a correr solo `make deploy-worker`.
- **Cambiaste el código del worker.** Basta con `make deploy-worker`; Terraform no se toca.
- **Las credenciales caducan.** Si un pipeline dice que no hay credenciales, cópialas otra vez
  del Learner Lab.
- **Los recursos cuestan crédito del lab mientras existan.** Al terminar, `make destroy`.

---

## 6. Preguntas

Respóndelas con tus palabras:

1. ¿Qué pasa con las ventas si el worker está apagado unos minutos? ¿Se pierden? ¿Por qué no?
2. ¿Qué ventaja tiene poner una cola entre el API y la base de datos?
3. ¿De dónde salen las IPs de MySQL y RabbitMQ que pusiste en el mapa? ¿Qué pasaría si las
   hubieras escrito a mano y la máquina de MySQL se reemplazara?
4. ¿Por qué `${...}` en la plantilla lo llena Terraform en tu computador, mientras que `$1` o
   `$REPOSITORY` los resuelve bash en la máquina?
5. Si corriges un error en `worker.py` y corres `make deploy-worker`, ¿qué cambia en AWS?
   ¿Por qué `terraform plan` sigue diciendo `No changes`?

---

## 7. Entregable

- `central-worker/worker.py`, `central-worker/models.py` e `infraestructura/compute.tf`.
- Las capturas de tu propia compra en cada paso de `GUIA-DE-PRUEBA.pdf`. Mínimo: PostgreSQL
  de la tienda, el log de tu worker, MySQL en AWS (`invoices` e `invoice_items`) y el
  dashboard.
- La salida de `make up`.
- Las respuestas a la sección 6.
