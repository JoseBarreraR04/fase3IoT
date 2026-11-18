# Cómo llega el código de tu computador a un contenedor Docker en AWS

Este documento sigue un servicio, el API central (`central-api/`), desde tu computador hasta
un contenedor corriendo en una máquina EC2. En el camino explica qué es un registro de
imágenes (ECR), qué son las plantillas `.tftpl` y por qué hay máquinas en `compute.tf` y
también en `scaling.tf`.

Léelo junto a los archivos que menciona. Los nombres de archivo son relativos a
`infraestructura/`, salvo que se diga otra cosa. El orden de despliegue y los comandos
están en `../DEPLOY.md`.

---

## 1. El viaje completo en un dibujo

```
 TU COMPUTADOR                                          AWS
 ─────────────                                          ───

 central-api/ ──(1) docker build ──▶ imagen ──(2) docker push──▶ ┌──────────────────┐
   Dockerfile       + pytest          20261101-153000             │ ECR              │
   app/             (central-api/deploy.sh)                       │ central-api:     │
                                                                  │   20261101-1530  │
                                       (3) mover la etiqueta ───▶ │   current ◀──────┼─┐
                                                                  └────────┬─────────┘ │
 templates/*.tftpl                                                         │           │
   + variables ──(A) templatefile()──▶ user_data ──(B)──┐                  │ (5) docker pull
   (Terraform, infraestructura/deploy.sh)               ▼                  ▼           │
                                              ┌──────────────────────────────────┐    │
                                              │ máquina EC2                      │    │
                                              │  (C) cloud-init corre user_data: │    │
                                              │      instala Docker y deja       │    │
                                              │      update-service.sh           │    │
                                              │  (5) update-service.sh baja      │────┘
                                              │      ...:current                 │
                                              │  (6) docker run → el servicio    │
                                              └──────────────────────────────────┘
                     (4) central-api/deploy.sh termina las máquinas y el grupo crea otras
                         (o, para el worker, le pide a SSM que corra update-service.sh)
```

Hay **dos caminos separados** que se encuentran en la máquina:

| Camino | Quién lo recorre | Qué lleva | Cada cuánto |
|---|---|---|---|
| A–C: la **máquina** | `infraestructura/deploy.sh` (Terraform) | un script de arranque con la configuración (IPs, claves) | cuando cambia la infraestructura |
| 1–6: el **código** | `central-api/deploy.sh` (y sus hermanos) | una imagen Docker en ECR | cada vez que cambia el código |

La idea clave: **Terraform nunca toca tu código.** Le da a cada máquina un *script* que sabe
ir a buscar la imagen `current` de su servicio. Los pipelines de servicio deciden cuál es
esa imagen.

---

## 2. El camino del código: imagen, ECR y la etiqueta `current`

`central-api/deploy.sh` hace, en orden:

```bash
docker build --platform linux/amd64 -t <registro>/central-api:20261101-153000 .  # (1)
docker run --rm <imagen> python -m pytest app -q                                 # pruebas
docker push <registro>/central-api:20261101-153000                               # (2)
aws ecr put-image ... --image-tag current                                        # (3)
aws autoscaling terminate-instance-in-auto-scaling-group --instance-id <id> ... # (4)
curl http://<balanceador>:8000/health                                            # verificar
```

- **ECR** (*Elastic Container Registry*) es un registro de imágenes Docker privado de tu
  cuenta, como Docker Hub pero en AWS. Hay un repositorio por servicio: `central-api`,
  `central-worker` y `central-web`. Los crea `infraestructura/deploy.sh` con la AWS CLI.
- Cada imagen se sube con una **versión** única: la fecha y hora UTC del despliegue.
  Las versiones viejas se quedan en ECR; así se puede volver atrás.
- **`current`** es una segunda etiqueta que se *mueve*: apunta a la versión que debe
  correr. Las máquinas solo conocen `current`. Moverla (`put-image`) no sube nada: le pone
  otro nombre a una imagen que ya está en ECR.
- `--platform linux/amd64`: las máquinas EC2 son Intel/AMD. Si construyes en un Mac con
  procesador ARM, sin esta opción la imagen no correría allá.

Por qué así y no construir en la máquina: la imagen se construye **una vez**, se prueba
**una vez**, y todas las máquinas corren exactamente esos bytes. Una máquina nueva no
tarda en compilar nada: baja la imagen y arranca.

---

## 3. El camino de la máquina: qué es una plantilla `.tftpl`

Un archivo `.tftpl` es un **texto con huecos**. La función `templatefile()` de Terraform
llena los huecos y devuelve texto normal. Este es `templates/worker.sh.tftpl` (resumido):

```bash
#!/bin/bash
${common}                                                     # ← hueco: un bloque entero de texto
echo 'REPOSITORY=central-worker' > /etc/central/service.conf
echo 'CENTRAL_DATABASE_URL=mysql+pymysql://${db_user}:${db_password}@${mysql_ip}:3306/${database}' > /etc/central/service.env
cat > /usr/local/bin/update-service.sh <<'SCRIPT'
${update_script}                                              # ← hueco: otro bloque
SCRIPT
wait_for ${mysql_ip} 3306                                     # ← hueco: un valor
/usr/local/bin/update-service.sh
```

Todo lo que se escribe `${nombre}` es un hueco. Terraform lo reemplaza con el valor de
`nombre` en el mapa que le pasas. En `compute.tf`:

```hcl
user_data = templatefile("${path.module}/templates/worker.sh.tftpl", {
  common        = local.common_script            # texto de otro archivo
  update_script = local.update_script            # texto de otra plantilla, ya llena
  mysql_ip      = aws_instance.mysql.private_ip  # una dirección que solo AWS conoce después de crear MySQL
  db_user       = var.mysql_user                 # una variable
  ...
})
```

El resultado es un script de bash normal, con los valores ya pegados:

```bash
echo 'CENTRAL_DATABASE_URL=mysql+pymysql://central:central_password@172.31.12.34:3306/central' > /etc/central/service.env
wait_for 172.31.12.34 3306
```

**Dos momentos, dos lenguajes.** La plantilla mezcla dos sistemas que usan `$`:

| Escribes | Quién lo lee | Cuándo | Significa |
|---|---|---|---|
| `${db_user}` | **Terraform** | en tu computador, durante `plan`/`apply` | pegar el valor |
| `$1`, `$i`, `$REPOSITORY`, `$(date)` | **bash** | después, en la máquina | bash normal |

Por eso las plantillas no usan `${...}` para variables de bash: Terraform intentaría
llenarlo y fallaría diciendo que la variable no está en el mapa. Si alguna vez necesitas
un `${` literal para bash, escribe `$${`.

### Tres piezas que se repiten

| Archivo | Qué es | Lo usan |
|---|---|---|
| `templates/common.sh.tftpl` | Primeros pasos de toda máquina: registro en `/var/log/central-bootstrap.log`, swap de 1 GB (un `t3.micro` tiene 1 GB de RAM), Docker, netcat y la función `wait_for HOST PUERTO`. No tiene huecos, por eso se lee con `file()` | todas |
| `templates/update-service.sh.tftpl` | El script que entra a ECR, baja `REPOSITORIO:current` (reintenta hasta 30 minutos si todavía no existe), borra el contenedor anterior y arranca el nuevo. Sus huecos son el registro y la región | API, worker, dashboard |
| `templates/<servicio>.sh.tftpl` | Lo propio del servicio: su configuración y en qué orden arranca | cada uno |

Lo que cada plantilla de servicio agrega después de `${common}`:

| Plantilla | Qué agrega |
|---|---|
| `mysql.sh.tftpl` | escribe el esquema y los datos iniciales (copiados de `../central-db/` con `file()`) y corre `mysql:8.4` |
| `rabbitmq.sh.tftpl` | corre `rabbitmq:3.13-management-alpine` |
| `api.sh.tftpl` | escribe `service.conf` y `service.env`, deja `update-service.sh`, espera a MySQL y RabbitMQ y lo ejecuta |
| `worker.sh.tftpl` | lo mismo que el API, pero sin publicar ningún puerto |
| `web.sh.tftpl` | lo mismo, sin esperar a nadie; su configuración es la dirección del API |

MySQL y RabbitMQ usan imágenes listas de Docker Hub; no tienen pipeline propio.

---

## 4. Cómo recibe la máquina el script (`user_data`)

`user_data` es un campo de la definición de la máquina. AWS guarda el texto y, en el primer
arranque, **cloud-init** (un programa que trae Amazon Linux) lo lee. Como empieza con
`#!/bin/bash`, lo ejecuta como script, con permisos de root.

Para recordar:

- Corre **una sola vez**, en el primer arranque. Apagar y prender la máquina no lo repite.
  Los contenedores vuelven solos porque arrancaron con `--restart unless-stopped`.
- Su salida queda en **`/var/log/central-bootstrap.log`**. Es lo primero que hay que mirar
  si un servicio no aparece.
- La última línea de cada script es `log "bootstrap finished OK"`. Si el registro no
  termina así, el script se detuvo antes (`set -euo pipefail` para en el primer error).
- `aws_instance` recibe el script como texto; una *launch template* lo necesita en
  **base64**. Por eso `scaling.tf` lo envuelve en `base64encode(...)`.

---

## 5. Qué pasa en la máquina

La máquina del worker, en orden (comentarios agregados aquí):

```bash
# --- de common.sh.tftpl ---
dd ... ; mkswap /swapfile ; swapon /swapfile               # memoria extra
dnf install -y docker nmap-ncat ; systemctl enable --now docker

# --- de worker.sh.tftpl ---
echo 'REPOSITORY=central-worker' > /etc/central/service.conf      # qué imagen
echo 'CENTRAL_DATABASE_URL=...'  > /etc/central/service.env       # su configuración
cat > /usr/local/bin/update-service.sh <<'SCRIPT' ... SCRIPT       # el script de actualización
wait_for 172.31.12.34 3306                                        # no arrancar antes que MySQL
wait_for 172.31.56.78 5672                                        # ... ni antes que RabbitMQ
/usr/local/bin/update-service.sh                                  # bajar current y arrancar

# --- dentro de update-service.sh ---
aws ecr get-login-password | docker login ... 892066436974.dkr.ecr.us-east-1.amazonaws.com
docker pull 892066436974.dkr.ecr.us-east-1.amazonaws.com/central-worker:current
docker rm -f central-worker
docker run -d --name central-worker --restart unless-stopped --env-file /etc/central/service.env <imagen>
```

**¿Cómo entra a ECR sin clave?** La máquina arranca con el perfil `LabInstanceProfile`,
cuyo rol tiene permiso para leer ECR y para recibir órdenes de SSM. AWS le entrega
credenciales temporales por una dirección interna y la AWS CLI las encuentra sola.

**La configuración no está en la imagen.** La misma imagen corre en tu computador (con
`docker compose`) y en AWS; lo que cambia es `service.env`, que Terraform llenó con las IPs
privadas de MySQL y RabbitMQ. Por eso la dirección de la base nunca aparece en el código
Python. (`--env-file` no admite comentarios al final de una línea; por eso la plantilla
escribe el archivo con `echo`, una línea por variable, y comenta cada `echo`).

| Máquina | Imagen | Configuración |
|---|---|---|
| `central-api` | `central-api:current` de ECR | `CENTRAL_DATABASE_URL`, `RABBITMQ_URL`, `INGESTION_QUEUE` |
| `central-worker` | `central-worker:current` de ECR | las mismas tres |
| `central-web` | `central-web:current` de ECR | `CENTRAL_API_UPSTREAM` (nginx la pone en su configuración) |
| `central-mysql` | `mysql:8.4` de Docker Hub | claves; el esquema se monta en `/docker-entrypoint-initdb.d` y MySQL lo ejecuta en su primer arranque |
| `central-rabbitmq` | `rabbitmq:3.13-management-alpine` de Docker Hub | usuario y clave |

---

## 6. `compute.tf` vs `scaling.tf`: ¿quién crea las máquinas?

Los dos archivos definen la *receta* de una máquina, pero solo uno las crea directamente.
La diferencia es **quién es responsable de la máquina**.

### La respuesta corta

| | `compute.tf` | `scaling.tf` |
|---|---|---|
| Servicios | `central-mysql`, `central-rabbitmq`, `central-worker` | `central-api`, `central-web` |
| Recurso de Terraform | `aws_instance` | `aws_launch_template` + `aws_autoscaling_group` |
| Quién crea la máquina | **Terraform**, directamente | **el grupo de autoescalado**, desde la launch template |
| Cuántas | exactamente 1 | 1 normalmente, hasta 2 (`max_instances`) |
| Si la máquina muere | nada; sigue muerta hasta volver a aplicar | el grupo lo nota y crea otra |
| En el estado de Terraform | sí, como `aws_instance.mysql` etc. | la receta y el grupo sí, **las máquinas no** |
| Se llega a ella por | su propia dirección | el balanceador (`balancer.tf`) |
| Código nuevo | worker: SSM corre `update-service.sh` en la misma máquina | se terminan; el grupo crea otras que bajan `current` |

### Por qué dos mecanismos

- **MySQL y RabbitMQ guardan datos.** Deben ser una máquina concreta que nunca se bota,
  por eso son `aws_instance` con `ignore_changes = [user_data]`: editar su plantilla no las
  reemplaza.
- **El API y el dashboard no guardan nada.** Cualquier copia sirve igual que otra, así que
  se pueden crear, destruir y multiplicar. Para eso existe un grupo de autoescalado.
- **El worker** también podría ser un grupo, pero nadie pidió más de uno. Como es una sola
  máquina fija, su código nuevo llega por **SSM** (*Systems Manager*), un servicio de AWS
  que le manda comandos a una máquina sin SSH. `user_data_replace_on_change = true` solo
  la reemplaza si cambia su configuración (por ejemplo, la IP de MySQL).

### Una launch template es un `aws_instance` que todavía no ha nacido

| `aws_instance` (en `compute.tf`) | `aws_launch_template` (en `scaling.tf`) |
|---|---|
| `ami = ...` | `image_id = ...` |
| `instance_type`, `key_name` | igual |
| `vpc_security_group_ids = [...]` | igual |
| `iam_instance_profile = "Lab..."` | `iam_instance_profile { name = "Lab..." }` |
| `root_block_device { volume_size }` | `block_device_mappings { ebs { volume_size } }` |
| `user_data = templatefile(...)` | `user_data = base64encode(templatefile(...))` |
| `tags = { Name = ... }` | `tag_specifications { tags = { Name = ... } }` |
| *(se crea en el acto)* | *(no se crea nada; es solo una receta)* |

Luego el grupo dice *"mantén entre 1 y 2 máquinas hechas con esta receta, regístralas en
ese grupo de destino y reemplaza la que deje de responder"*.

```
 compute.tf                                   scaling.tf  +  balancer.tf
 ──────────                                   ─────────────────────────
 aws_instance.mysql  ──▶ 1 máquina            aws_launch_template.api  (receta)
 aws_instance.rabbitmq ─▶ 1 máquina                     │
 aws_instance.worker ──▶ 1 máquina            aws_autoscaling_group.api ──▶ 1..2 máquinas
                                                        │                    ▲
                                              aws_lb_target_group.api ◀──────┘ (las registra)
                                                        │
                                              aws_lb ─▶ la dirección pública
```

### Una consecuencia que vas a notar

`terraform output ssh_addresses` solo lista MySQL, RabbitMQ y el worker. Las máquinas del
API y del dashboard las crea AWS, no Terraform, así que Terraform no sabe sus direcciones:

```bash
aws ec2 describe-instances \
  --filters Name=tag:Name,Values=central-api Name=instance-state-name,Values=running \
  --query 'Reservations[].Instances[].PublicIpAddress' --output text
```

---

## 7. Qué pasa cuando cambias el código

Editas un archivo de `central-api/` y corres `make deploy-api`:

```
archivo editado
   │
   ▼
build + test + push       → nueva imagen central-api:20261101-160000 en ECR
   │
   ▼
promote                   → current apunta a la nueva (se guarda cuál era la anterior)
   │
   ▼
rollout                   → terminar las máquinas del grupo central-api:
   │                         el grupo debe tener 1, así que crea otra, que baja current
   │                         al arrancar (el API no responde unos minutos)
   ▼
verify                    → GET /health por el balanceador
   │
   └── si falla:  rollback → current vuelve a la anterior y se repite el rollout
```

Por qué no "sin corte": AWS tiene *instance refresh*, que arranca la máquina nueva antes de
apagar la vieja, pero el Learner Lab lo prohíbe. En este curso aceptamos unos minutos sin
API; las tiendas guardan las ventas y reintentan. La alta disponibilidad es otro laboratorio.

Lo que **no** pasa: Terraform no se entera. `terraform plan` sigue diciendo *"No changes"*,
el worker y el dashboard no se tocan, y MySQL y RabbitMQ tampoco.

Con el worker es igual hasta `promote`; el `rollout` es una orden de SSM para que su máquina
vuelva a correr `update-service.sh`, y el `verify` revisa por SSM que el contenedor corra la
imagen nueva sin reiniciarse.

Y si cambias la **infraestructura** (`make infra`): una máquina nueva del API arranca y baja
la `current` que ya existe. Por eso el *grace period* del grupo es de solo 300 s: instalar
Docker y bajar una imagen tarda unos 2 o 3 minutos.

---

## 8. Cuando algo no aparece

| Síntoma | Dónde mirar |
|---|---|
| `502 Bad Gateway` justo después de crear la infraestructura | las máquinas esperan su imagen: corre los pipelines de servicio (`../DEPLOY.md`) |
| Un pipeline falla en `preflight` | lee el mensaje: falta la infraestructura, el repositorio o las credenciales |
| Un destino del balanceador sigue `unhealthy` | `aws elbv2 describe-target-health --target-group-arn <arn>` |
| Un servicio nunca arranca | SSH y lee `/var/log/central-bootstrap.log`; termina en `bootstrap finished OK` si todo salió bien |
| El registro dice `la imagen ... todavía no está disponible` | falta correr el pipeline de ese servicio |
| El registro se queda en `esperando a 172...:3306` | MySQL no responde, o el firewall de la máquina no es el correcto |
| Una actualización falló | `/var/log/central-update.log` en la máquina |
| El contenedor arrancó pero se porta mal | `sudo docker logs central-api` (o `central-worker`, `central-web`) |
| Quieres ver el script tal como lo recibió la máquina | `aws ec2 describe-instance-attribute --instance-id <id> --attribute userData` (viene en base64) |
| Quieres ver el script *antes* de desplegar | `terraform console`, y luego `templatefile("templates/worker.sh.tftpl", {...})` |

---

## 9. Referencia rápida: qué hace cada archivo

| Archivo | Papel |
|---|---|
| `deploy.sh` | pipeline de infraestructura: repositorios ECR, `terraform plan` y `apply`, `.env.cloud` |
| `destroy.sh` | borra la infraestructura, los repositorios ECR y `.env.cloud` |
| `../central-api/deploy.sh`, `../central-worker/deploy.sh`, `../central-web/deploy.sh` | pipelines de servicio: build, test, push, promote, rollout, verify, rollback |
| `templates/common.sh.tftpl` | primeros pasos de toda máquina (swap, Docker, `wait_for`) |
| `templates/update-service.sh.tftpl` | baja `current` de ECR y reemplaza el contenedor |
| `templates/<servicio>.sh.tftpl` | configuración y orden de arranque de cada servicio |
| `compute.tf` | búsqueda de la imagen del sistema, dirección del registro y las tres máquinas fijas |
| `scaling.tf` | launch templates y grupos de autoescalado del API y el dashboard |
| `balancer.tf` | el balanceador que da una dirección pública a los grupos |
| `network.tf` | firewalls (security groups) y subredes donde pueden ir las máquinas |
| `variables.tf` / `outputs.tf` | los parámetros y los resultados impresos |
| `check-comments.sh` | revisa que cada línea de código tenga comentario (la regla de la clase) |
