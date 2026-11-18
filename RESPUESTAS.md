# Respuestas: sección 6 de TO-DO.md

## 1. ¿Qué pasa con las ventas si el worker está apagado unos minutos? ¿Se pierden? ¿Por qué no?

No se pierden. Se quedan esperando en la cola de RabbitMQ hasta que el worker vuelve.

- El API publica cada lote en una cola **durable** y con mensajes **persistentes**
  (`delivery_mode=2`), así que RabbitMQ los guarda en disco y sobreviven incluso a un reinicio
  de RabbitMQ.
- El API solo responde `202 Accepted` cuando RabbitMQ confirmó que recibió el lote
  (*publisher confirms*). Solo entonces la tienda marca las ventas con `forwarded_at`.
- El worker confirma cada mensaje (`ack`) **después** de guardar el lote en MySQL. Si se apaga
  a mitad de un lote, ese mensaje no tiene `ack` y RabbitMQ lo vuelve a entregar cuando el
  worker reconecta.

Mientras el worker está apagado, la cola muestra mensajes en espera y 0 consumidores. Al volver,
el worker los procesa todos y las ventas aparecen en el dashboard, solo que más tarde.

## 2. ¿Qué ventaja tiene poner una cola entre el API y la base de datos?

- **Desacople:** el API ya no depende de que MySQL esté disponible para recibir ventas. Si
  MySQL o el worker fallan, las tiendas siguen enviando y el API sigue respondiendo.
- **Absorbe picos:** si llegan muchos lotes a la vez, se acumulan en la cola y el worker los
  guarda a su ritmo, sin saturar la base de datos.
- **Respuesta rápida:** el API solo valida la forma y encola. No espera a que terminen los
  inserts.
- **Cada parte escala por separado:** se pueden agregar máquinas del API o más workers sin
  tocar la otra parte.
- **Reintentos sin duplicados:** si guardar falla, el mensaje vuelve a la cola. Como el worker
  salta las facturas que ya existen (misma tienda y mismo número), reintentar no duplica ventas.

## 3. ¿De dónde salen las IPs de MySQL y RabbitMQ que pusiste en el mapa? ¿Qué pasaría si las hubieras escrito a mano y la máquina de MySQL se reemplazara?

Salen de los atributos de las máquinas que Terraform crea en el mismo `compute.tf`:
`aws_instance.mysql.private_ip` y `aws_instance.rabbitmq.private_ip`. Terraform conoce esas IPs
después de crear las máquinas. Esa referencia también le indica el orden: primero crea MySQL y
RabbitMQ, y después el worker con sus IPs ya puestas en la plantilla.

Si las hubiera escrito a mano y la máquina de MySQL se reemplazara, la nueva tendría otra IP
privada. El worker seguiría apuntando a la IP vieja: el arranque se quedaría en
`esperando a ...:3306` y los lotes se acumularían en la cola sin guardarse nunca. Con la
referencia, al reemplazar MySQL cambia el valor del mapa, cambia el `user_data` del worker y,
por `user_data_replace_on_change = true`, Terraform crea un worker nuevo con la IP correcta.

## 4. ¿Por qué `${...}` en la plantilla lo llena Terraform en tu computador, mientras que `$1` o `$REPOSITORY` los resuelve bash en la máquina?

Son dos momentos distintos:

1. **En mi computador, durante `terraform apply`:** `templatefile()` lee el `.tftpl` y reemplaza
   cada `${nombre}` por el valor del mapa. El resultado es un script de bash normal, con las IPs,
   usuarios y claves ya escritos, y eso es lo que se envía a AWS como `user_data`. La máquina
   nunca ve un `${mysql_ip}`: recibe directamente la IP.
2. **En la máquina, al arrancar:** bash ejecuta ese script. Las variables de bash, como `$1`,
   `$REPOSITORY` o `$IMAGE`, solo existen ahí, en tiempo de ejecución: `$REPOSITORY` sale de
   `/etc/central/service.conf`, que el mismo script escribe en la máquina, y `$1` es el argumento
   que recibe una función. Terraform no puede conocer esos valores.

Terraform solo reemplaza la forma con llaves, `${...}`. Un `$VARIABLE` sin llaves lo deja
intacto para bash. Si hiciera falta escribir `${...}` literal para bash, se escribiría `$${...}`.

## 5. Si corriges un error en `worker.py` y corres `make deploy-worker`, ¿qué cambia en AWS? ¿Por qué `terraform plan` sigue diciendo `No changes`?

Lo que cambia en AWS:

1. Se sube una imagen nueva al repositorio ECR `central-worker`, con su versión
   `AAAAMMDD-HHMMSS`.
2. La etiqueta `current` pasa a apuntar a esa imagen.
3. Por SSM, la máquina del worker (la misma, no una nueva) ejecuta
   `/usr/local/bin/update-service.sh`: baja `central-worker:current`, borra el contenedor viejo
   y arranca el nuevo.
4. La etapa `verify` comprueba que el contenedor siga vivo, sin reinicios y sin `Traceback`. Si
   algo falla, vuelve `current` a la versión anterior (*rollback*).

`terraform plan` sigue diciendo `No changes` porque el código no es parte de la
infraestructura. Terraform solo describe máquinas, red, firewalls, balanceador y repositorios, y
nada de eso cambió. El `user_data` del worker no contiene el código: solo dice "baja la imagen
`current`", y ese texto es el mismo. La versión del código vive en ECR (la etiqueta `current`),
fuera del estado de Terraform.
