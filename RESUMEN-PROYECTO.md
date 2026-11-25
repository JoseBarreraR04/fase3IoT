# Resumen completo del proyecto: D1 Chain Simulator (Fase 3)

> Para **probarlo** paso a paso, lee `GUIA-PASO-A-PASO.md`. Para Terraform en detalle, `TERRAFORM-EXPLICADO.md`. Este archivo explica **qué es y
> cómo funciona** cada parte.

## Índice

1. [La idea en una frase](#1-la-idea-en-una-frase)
2. [Glosario rápido](#2-glosario-rápido)
3. [Arquitectura](#3-arquitectura)
4. [El recorrido de una compra](#4-el-recorrido-de-una-compra)
5. [Las tiendas](#5-las-tiendas-corren-en-tu-pc)
6. [La sede central](#6-la-sede-central)
7. [El worker en detalle](#7-el-worker-en-detalle-el-ejercicio)
8. [Las bases de datos](#8-las-bases-de-datos)
9. [Modo local: Docker Compose y redes](#9-modo-local-docker-compose-y-redes)
10. [Modo nube: Terraform explicado](#10-modo-nube-terraform-explicado)
11. [Cómo llega el código a AWS: pipelines, ECR y SSM](#11-cómo-llega-el-código-a-aws-pipelines-ecr-y-ssm)
12. [Tolerancia a fallos: por qué no se pierden ventas](#12-tolerancia-a-fallos-por-qué-no-se-pierden-ventas)
13. [Comandos `make`](#13-comandos-make)
14. [Puertos y direcciones](#14-puertos-y-direcciones)
15. [Estado del ejercicio](#15-estado-del-ejercicio)

---

## 1. La idea en una frase

Simula una cadena de supermercados (D1): **2 tiendas** venden con sus cajas y, cada cierto
tiempo, mandan sus ventas por **lotes** a una **sede central**. La sede las pone en una
**cola** (RabbitMQ), un **worker** las guarda en **MySQL** y un **dashboard** muestra cuánto vendió
cada tienda y los productos más vendidos.

Las tiendas siempre corren en tu PC (Docker). La sede central puede correr en tu PC (modo local)
o en **AWS** (modo nube, el del ejercicio).

---

## 2. Glosario rápido

| Término | Qué significa aquí |
|---|---|
| **Imagen / contenedor** | Imagen = programa empaquetado (Dockerfile). Contenedor = imagen corriendo. |
| **Docker Compose** | `docker-compose.yml`: define los 20 contenedores locales, redes y volúmenes. |
| **Volumen** | Disco de un contenedor que sobrevive cuando el contenedor se borra (bases de datos, cola). |
| **API** | Servicio HTTP (aquí FastAPI en Python) que recibe y responde peticiones. |
| **Lote (batch)** | Grupo de ventas de una tienda enviado de una sola vez a la sede. |
| **Cola (RabbitMQ)** | "Buzón" donde el API deja lotes y el worker los recoge. Guarda en disco. |
| **ack / nack / reject** | Respuestas del worker a RabbitMQ: *ack* = listo, bórralo; *nack* = devuélvelo a la cola; *reject* = descártalo. |
| **Idempotencia** | Procesar lo mismo dos veces da el mismo resultado (no duplica ventas). |
| **EC2** | Máquina virtual de AWS. |
| **VPC / subred** | Red privada de AWS donde viven las máquinas. |
| **Security group** | Firewall de AWS: qué puertos y desde dónde pueden entrar. |
| **ALB** | *Application Load Balancer*: la única puerta pública; reparte tráfico a las máquinas. |
| **Auto Scaling Group (ASG)** | Mantiene N máquinas vivas; crea más si hay carga y reemplaza las enfermas. |
| **Launch template** | "Receta" que usa el ASG para crear cada máquina. |
| **user_data** | Script que una EC2 ejecuta **una vez** al primer arranque. |
| **ECR** | Registro privado de imágenes Docker en AWS. |
| **SSM** | Servicio de AWS para mandarle comandos a una máquina sin SSH. |
| **Terraform** | Herramienta que crea la infraestructura descrita en archivos `.tf`. |
| **`.tftpl`** | Plantilla: texto con huecos `${...}` que Terraform rellena. |
| **Learner Lab** | Cuenta temporal de AWS del curso, con credenciales que caducan. |

---

## 3. Arquitectura

```
                    TU COMPUTADOR (Docker)                            │      AWS (Learner Lab)  ó  tu PC en modo local
                                                                      │
 ┌────────────── TIENDA 1 (store-1-net) ───────────────┐              │
 │ register-1 :8081   register-2 :8082   (cajas)       │              │   ┌────────── central ──────────┐
 │      │                  │                           │              │   │                             │
 │      └──► frontend ──► backend ──► postgres          │              │   │   ALB :80  ─► central-web    │
 │                          │   └─► redis (caché)      │              │   │   ALB :8000 ─► central-api ──┼─► RabbitMQ
 │                     sync ─┼──────────────────────────┼──── WAN ────►│   │                    │        │     │
 └───────────────────────────┼──────────────────────────┘   (wan-net)  │   │                    ▼        │     ▼
                             ▼                                         │   │                 MySQL ◄─────┼── worker
                      payment-gateway (pasarela de pagos, "tercero")   │   └─────────────────────────────┘
 ┌────────────── TIENDA 2 (store-2-net) ─── igual, cajas :8083 :8084 ──┘
```

- Cada tienda está **aislada** en su red; solo `backend` (para pagar) y `sync` (para enviar ventas)
  salen a la "WAN".
- La sede central solo se alcanza por el **API**. Nadie de afuera llega a MySQL ni a RabbitMQ.

---

## 4. El recorrido de una compra

| # | Dónde | Qué pasa | Cómo se ve |
|---|---|---|---|
| 1 | Caja (`register`) | El cajero agrega productos por código de barras (EAN) y paga. | http://localhost:8081 |
| 2 | `backend` + `payment-gateway` | El backend busca productos (con caché Redis), cobra en la pasarela (rechaza montos > 1.000.000) y guarda la venta. | — |
| 3 | PostgreSQL de la tienda | Tablas `sales` y `sale_items`. `forwarded_at` = vacío (pendiente de enviar). | `psql` |
| 4 | `sync` (forwarder) | Cada 5 s revisa pendientes. Envía lote si hay **10 ventas** o la más vieja tiene **60 s**. `POST /sales/batch` al API central. | log de `store-1-sync` |
| 5 | `central-api` | Valida el lote (Pydantic), lo publica en RabbitMQ (durable + persistente + confirmación) y responde **202 Accepted**. | — |
| 6 | Tienda | Al recibir 202, marca `forwarded_at` con la fecha. | `psql` |
| 7 | RabbitMQ | El lote espera en la cola `invoice-batches`. | `rabbitmqctl list_queues` |
| 8 | `central-worker` | Saca el lote, valida, quita duplicados, guarda en MySQL en una transacción y hace **ack**. | `docker logs central-worker` |
| 9 | MySQL central | Filas en `invoices` e `invoice_items`. | consulta SQL |
| 10 | `central-web` | El dashboard pide `/api/reports/...` al API cada 10 s y grafica. | navegador |

---

## 5. Las tiendas (corren en tu PC)

Las dos tiendas usan **el mismo código**; solo cambian nombre, red, puerto y volumen.

| Carpeta → contenedor | Qué hace |
|---|---|
| `register/` → `store-N-register-1/2` | La **caja**: nginx que sirve la web de la tienda. Es la única puerta a la tienda desde tu navegador. Trae `integration_tests.py`. |
| `frontend/` → `store-N-frontend` | La web (HTML/JS) del punto de venta. Reenvía `/api` a su backend. |
| `backend/` → `store-N-backend` | API de la tienda (FastAPI). Módulos: `products` (`GET /products/{ean}`, con caché Redis), `sales` (ventas, estado de envío), `payments` (`POST /payments`, llama a la pasarela). |
| Redis → `store-N-redis` | Caché de productos: no consulta PostgreSQL en cada escaneo. |
| `db/` → `store-N-postgres` | Base de la tienda: productos, `sales`, `sale_items`. Esquema y semilla en `db/*.sql`. |
| `sync/` → `store-N-sync` | **Forwarder**: lee ventas con `forwarded_at` vacío, arma el lote y lo envía al API central; si la sede está caída, reintenta en el siguiente ciclo sin perder nada. |
| `payment-gateway/` | Pasarela de pagos simulada, de nadie (como un banco). Guarda sus cobros en SQLite. Rechaza montos sobre `DECLINE_THRESHOLD`. |

Código organizado igual en cada servicio Python: `app/core/` (config, base de datos, logging) +
una carpeta por dominio (`router.py` = HTTP, `service.py` = lógica, `repository.py` = SQL,
`schemas.py` = formatos, `models.py` = tablas, `tests/`).

---

## 6. La sede central

| Carpeta → contenedor | Qué hace |
|---|---|
| `central-api/` | API central (FastAPI). Endpoints: `GET /health`, `POST /sales/batch` (recibe lotes → cola), `GET /reports/sales-by-store`, `GET /reports/top-products`, `GET /stores`. |
| `central-api/app/ingestion/` | `schemas.py` valida el lote; `publisher.py` lo publica en RabbitMQ; `service.py` une ambas cosas. **Ya no escribe en MySQL** (eso es del worker). |
| `central-api/app/reports/` | Consultas de agregación sobre MySQL para el dashboard. |
| `central-worker/` | Consume la cola y guarda en MySQL (ver sección 7). |
| `central-db/` | `01-schema.sql` (tablas) y `02-seed.sql` (las 2 tiendas). Se ejecutan al primer arranque de MySQL. |
| RabbitMQ (`rabbitmq:3.13-management`) | La cola `invoice-batches`. Panel web en el puerto 15672. |
| `central-web/` | Dashboard: `index.html`, `app.js`, `charts.js`, nginx que reenvía `/api` al API. |

**Formato del lote** (lo que viaja por la cola, JSON):

```json
{
  "store_id": "store-1",
  "invoices": [
    {
      "store_invoice_id": 1,
      "register_id": "store-1-register-1",
      "sold_at": "2026-11-04T03:34:29.142040",
      "total": "13600.00",
      "items": [
        { "ean": "7702001010301", "product_name": "Arroz Diana 500g",
          "quantity": 2, "unit_price": "3200.00", "subtotal": "6400.00" }
      ]
    }
  ]
}
```

Los montos viajan como **texto** para no perder centavos con números decimales de JSON.

---

## 7. El worker en detalle (el ejercicio)

Carpeta propia, independiente (no importa nada de `central-api`):

| Archivo | Contenido |
|---|---|
| `Dockerfile` | Python 3.12 slim, instala dependencias, copia `worker.py` y `models.py`, corre como usuario sin root, `CMD python worker.py`. No abre puertos. |
| `requirements.txt` | `pika` (RabbitMQ), `sqlalchemy` (ORM), `pymysql` (driver MySQL), `cryptography`. |
| `models.py` | Clases SQLAlchemy `Store`, `Invoice`, `InvoiceItem` = mismas columnas que `01-schema.sql`. `Invoice.items` es una relación: al guardar una factura se guardan sus artículos. |
| `worker.py` | La lógica (abajo). |
| `deploy.sh` | Su pipeline hacia AWS (sección 11). |

**Variables de entorno:** `CENTRAL_DATABASE_URL` (`mysql+pymysql://usuario:clave@host:3306/central`),
`RABBITMQ_URL` (`amqp://usuario:clave@host:5672/%2F`), `INGESTION_QUEUE` (`invoice-batches`).

**Arranque (`main`)**

1. Crea el motor de SQLAlchemy con `pool_pre_ping` (descarta conexiones muertas).
2. `wait_for_database`: intenta `SELECT 1` cada 5 s hasta que MySQL responda.
3. Conecta a RabbitMQ, declara la cola **durable** (igual que el API), `prefetch_count=1` (un lote
   a la vez) y `auto_ack=False` (él decide cuándo confirmar).
4. Si RabbitMQ se cae, espera 5 s y se reconecta (bucle infinito: nunca termina el proceso).

**Por cada mensaje (`on_message` → `save_batch`)**

1. `parse_batch`: JSON válido, `store_id` texto ≤ 20, `invoices` lista. Si no → mensaje inválido.
2. La tienda debe existir en `stores`. Si no → inválido (el worker no inventa tiendas).
3. `parse_invoice` / `parse_item` por cada factura: tipos, largos de columna, `quantity > 0`,
   montos ≥ 0, máx. 2 decimales y que quepan en `DECIMAL(12,2)`, fecha ISO. Una factura mala se
   **omite y se registra**; las demás siguen.
4. **Idempotencia:** consulta qué `store_invoice_id` de esa tienda ya existen y los salta
   (también los repetidos dentro del mismo lote).
5. Agrega las nuevas con `received_at` = ahora (UTC) y hace **un solo `commit`**.
6. Solo después: **`ack`** y log `lote de store-1 guardado: N facturas, X nuevas, Y duplicadas, Z inválidas`.

**Qué hace ante errores**

| Error | Acción | Por qué |
|---|---|---|
| Mensaje inválido (JSON roto, tienda inexistente) | `reject` sin reencolar + log | Reintentarlo daría siempre el mismo error. |
| MySQL caído (códigos 2003/2006/2013) | `rollback`, espera 5 s, `nack` con reencolar | El lote no se pierde; se reintenta cuando MySQL vuelva. |
| Otro error de base de datos o inesperado | 1 reintento; si llega de nuevo (`redelivered`) → `reject` | Evita un bucle infinito con un mensaje "venenoso". |

**Detalle importante:** el pipeline da el despliegue por fallido si el log contiene
`Traceback` o el contenedor se reinicia. Por eso el worker registra errores en una sola línea y
silencia los tracebacks internos de `pika`.

**Localmente** se levanta con `make up-local` (perfil `central` de Compose). **En AWS** corre en su
propia EC2 `central-worker`.

---

## 8. Las bases de datos

**PostgreSQL de cada tienda** (`db/01-schema.sql`): productos, `sales` (con `forwarded_at`: vacío =
pendiente, con fecha = ya lo recibió la sede) y `sale_items`.

**MySQL central** (`central-db/01-schema.sql`):

| Tabla | Columnas clave | Reglas |
|---|---|---|
| `stores` | `id` (`store-1`), `name` | Sembrada en `02-seed.sql`; el API y el worker solo la leen. |
| `invoices` | `id`, `store_id`, `store_invoice_id`, `register_id`, `sold_at`, `received_at`, `total` | `UNIQUE(store_id, store_invoice_id)` = garantía anti-duplicados. `total ≥ 0`. FK a `stores`. |
| `invoice_items` | `id`, `invoice_id`, `ean`, `product_name`, `quantity`, `unit_price`, `subtotal` | `quantity > 0`, montos ≥ 0. FK a `invoices` con `ON DELETE CASCADE`. |

- `sold_at` (cuándo se vendió en la tienda) ≠ `received_at` (cuándo llegó a la sede): la
  diferencia muestra el retraso del envío por lotes.
- `product_name` se copia en cada línea: la sede no tiene catálogo, y una factura es un documento
  histórico.
- Índices en `invoices.store_id`, `invoice_items.invoice_id` e `invoice_items.ean` para los reportes.

---

## 9. Modo local: Docker Compose y redes

`docker-compose.yml` define **20 contenedores**: 7 por tienda (2 cajas, frontend, backend,
postgres, sync, redis) + pasarela + 5 de la sede (mysql, api, web, rabbitmq, worker). Los de la
sede tienen `profiles: ["central"]`: solo arrancan con `--profile central` (`make up-local`);
con `make up-stores` no arrancan porque la sede está en AWS.

| Red | Quién está | Para qué |
|---|---|---|
| `store-1-net` / `store-2-net` | Todo lo de cada tienda | Aislar cada tienda. |
| `central-net` | mysql, rabbitmq, api, web, worker | La LAN de la sede. |
| `wan-net` | backend y sync de cada tienda, central-api, payment-gateway | La "internet" simulada. |

Ejemplos: una caja **no** llega a la pasarela ni a la sede; `sync` llega al API pero **no** a
MySQL. Volúmenes: `store-1-data`, `store-2-data`, `central-data`, `gateway-data`, `rabbitmq-data`.

Variables en `.env` (copiado de `.env.example`): nombres de tiendas, claves, puertos, `BATCH_SIZE`,
`BATCH_MAX_AGE_SECONDS`, `SYNC_POLL_SECONDS`, `DECLINE_THRESHOLD`, etc. En modo nube,
`infraestructura/deploy.sh` escribe `.env.cloud` con `CENTRAL_API_PUBLIC_URL` (la URL del
balanceador) para que `sync` envíe a AWS.

---

## 10. Modo nube: Terraform explicado

### 10.1 Qué es y cómo trabaja

Terraform lee todos los `.tf` de `infraestructura/` como **un solo documento** (el orden de los
archivos no importa). Tú describes **qué** quieres; él calcula **en qué orden** crearlo mirando
las referencias (`aws_instance.mysql.private_ip` dentro del worker ⇒ primero MySQL, después el
worker).

| Comando | Qué hace |
|---|---|
| `terraform init` | Descarga el proveedor de AWS. |
| `terraform fmt` | Ordena el formato. |
| `terraform validate` | Revisa que la configuración sea válida (sin tocar AWS). |
| `terraform plan` | Muestra qué va a crear, cambiar o borrar. |
| `terraform apply` | Lo hace. Guarda lo creado en `terraform.tfstate`. |
| `terraform output` | Muestra las salidas (URLs, IPs). |
| `terraform destroy` | Borra todo lo que creó. |

Piezas del lenguaje que aparecen:

- `resource "tipo" "nombre"` → algo que Terraform **crea** (máquina, firewall…).
- `data "tipo" "nombre"` → algo que solo **lee** de AWS (la VPC por defecto, la AMI más nueva).
- `variable` → entrada configurable (con valor por defecto). Se usa como `var.nombre`.
- `locals` → valores calculados una vez. Se usan como `local.nombre`.
- `output` → valor que imprime al final.
- `lifecycle` → reglas especiales (ej. no reemplazar una máquina).

### 10.2 Archivo por archivo

#### `versions.tf`
- Terraform ≥ 1.5 y proveedor `hashicorp/aws ~> 6.0`.
- `provider "aws"`: región `var.region` y la etiqueta `Project = d1-chain` en **todo** (así
  `destroy.sh` y los comandos `aws ec2 describe-instances` encuentran los recursos).

#### `variables.tf` (todas con valor por defecto)

| Variable | Defecto | Para qué |
|---|---|---|
| `region` | `us-east-1` | Región (el lab solo permite us-east-1 / us-west-2). |
| `instance_type` | `t3.micro` | Tamaño de todas las EC2 (2 vCPU, 1 GB). |
| `max_instances` | `2` | Máximo de máquinas en cada ASG. |
| `key_name` | `vockey` | Par de llaves SSH del lab (`labsuser.pem`). |
| `instance_profile` | `LabInstanceProfile` | Rol IAM: permite bajar de ECR y recibir órdenes SSM. |
| `ssh_cidr` | `0.0.0.0/0` | Desde dónde se permite SSH. |
| `mysql_root_password`, `mysql_database`, `mysql_user`, `mysql_password` | `central…` | Credenciales MySQL (iguales a las locales). |
| `rabbitmq_user`, `rabbitmq_password` | `central…` | Credenciales RabbitMQ. |
| `ingestion_queue` | `invoice-batches` | Nombre de la cola. |

Para cambiar alguna: copia `terraform.tfvars.example` a `terraform.tfvars`.

#### `network.tf`
- `data aws_vpc.default` → usa la VPC que toda cuenta trae.
- `data aws_ec2_instance_type_offerings` + `data aws_subnets.default` → solo subredes en zonas
  donde existe `t3.micro` (si no, a veces falla crear la máquina).
- **6 security groups:**

| Grupo | Entrada permitida | Salida |
|---|---|---|
| `alb` | 80 y 8000 desde internet | todo |
| `web` | 80 solo desde `alb`; SSH | todo |
| `api` | 8000 solo desde `alb`; SSH | todo |
| `worker` | **solo SSH** (nadie se conecta al worker; él se conecta a otros) | todo |
| `rabbitmq` | 5672 solo desde `api` y `worker`; SSH | todo |
| `mysql` | 3306 solo desde `api` y `worker`; SSH | todo |

Usar **grupos como origen** (no IPs) significa "cualquier máquina con ese firewall", aunque el ASG
cree máquinas nuevas con otra IP.

#### `compute.tf`
- `data aws_ami.al2023` → busca la imagen **Amazon Linux 2023** más reciente (no un id fijo).
- `data aws_caller_identity` → número de cuenta (para armar la dirección de ECR).
- `locals`:
  - `registry` = `<cuenta>.dkr.ecr.<región>.amazonaws.com`.
  - `common_script` = `common.sh.tftpl` leído tal cual (swap de 1 GB, instala Docker y netcat,
    define `log` y `wait_for`).
  - `update_script` = `update-service.sh.tftpl` con `registry` y `region` rellenados.
- `aws_instance.mysql`: disco 16 GB, `user_data` = `mysql.sh.tftpl` con el esquema y la semilla
  de `central-db/` **incrustados**, y las claves. `lifecycle { ignore_changes = [user_data] }` →
  **nunca se reemplaza** (perdería los datos).
- `aws_instance.rabbitmq`: igual, con `rabbitmq.sh.tftpl`; nunca se reemplaza (perdería mensajes
  pendientes).
- `aws_instance.worker` (**lo del ejercicio**): `user_data` = `worker.sh.tftpl` con el mapa:

| Hueco `${...}` | Valor | Tipo |
|---|---|---|
| `common` | `local.common_script` | local |
| `update_script` | `local.update_script` | local |
| `mysql_ip` | `aws_instance.mysql.private_ip` | atributo de otra máquina |
| `rabbitmq_ip` | `aws_instance.rabbitmq.private_ip` | atributo de otra máquina |
| `database` | `var.mysql_database` | variable |
| `db_user` | `var.mysql_user` | variable |
| `db_password` | `var.mysql_password` | variable |
| `rabbitmq_user` | `var.rabbitmq_user` | variable |
| `rabbitmq_password` | `var.rabbitmq_password` | variable |
| `queue` | `var.ingestion_queue` | variable |

  `user_data_replace_on_change = true` → si cambia algo del mapa (ej. la IP de MySQL), Terraform
  crea un worker nuevo. El **código** del worker no está aquí: llega por ECR + SSM.

#### `scaling.tf`
- `aws_launch_template.api`: receta de cada máquina del API. Mismo mapa que el worker (por eso el
  TO-DO dice "guíate por scaling.tf"). El `user_data` va en `base64encode(...)` porque las launch
  templates lo exigen.
- `aws_launch_template.web`: receta del dashboard; recibe `api_host = aws_lb.main.dns_name` para
  que nginx reenvíe `/api` al balanceador.
- `aws_autoscaling_group.api` / `.web`: mínimo 1, deseado 1, máximo `var.max_instances` (2).
  Registran sus máquinas en el target group del ALB; `health_check_type = "ELB"` (si el ALB la ve
  enferma, la reemplaza); 300 s de gracia para que arranque. `ignore_changes = [desired_capacity]`
  para no deshacer un escalado.
- `aws_autoscaling_policy.api_cpu` / `.web_cpu`: *target tracking* a **60 % de CPU**: sobre eso
  agrega una máquina, muy por debajo la quita.

**¿Por qué unas máquinas en `compute.tf` y otras en `scaling.tf`?** MySQL, RabbitMQ y el worker son
**una sola** máquina con estado o con un único consumidor: se crean directo (`aws_instance`). API y
dashboard son **sin estado** y deben poder ser 1 o 2: los crea un ASG desde una launch template.

#### `balancer.tf`
- `aws_lb.main` ("central-alb"): balanceador de aplicación en las subredes por defecto.
- `aws_lb_target_group.api` (puerto 8000, salud `GET /health`) y `.web` (puerto 80, salud `GET /`):
  2 aciertos = sana, 3 fallos = enferma, revisión cada 15 s.
- `aws_lb_listener.web` (puerto 80 → web) y `.api` (puerto 8000 → api).

#### `outputs.tf`
- `central_api_url` = `http://<dns del ALB>:8000` (lo usan las tiendas).
- `central_web_url` = `http://<dns del ALB>` (el dashboard).
- `ecr_registry` = `local.registry`.
- `ssh_addresses` = IP pública de mysql, rabbitmq y **worker** (cambian si el lab se reinicia).

### 10.3 Las plantillas (`templates/*.tftpl`)

| Plantilla | Máquina | Qué hace al arrancar |
|---|---|---|
| `common.sh.tftpl` | todas | Swap 1 GB, instala Docker y netcat, define `log` (escribe en `/var/log/central-bootstrap.log`) y `wait_for HOST PUERTO`. |
| `mysql.sh.tftpl` | mysql | Escribe el esquema y la semilla, arranca el contenedor MySQL con las claves. |
| `rabbitmq.sh.tftpl` | rabbitmq | Arranca RabbitMQ con su usuario y clave. |
| `api.sh.tftpl` | API | Escribe su config/env (MySQL, RabbitMQ, cola), espera a ambos y corre `update-service.sh`. |
| `web.sh.tftpl` | dashboard | Configura el destino `/api` y corre `update-service.sh`. |
| `worker.sh.tftpl` | worker | Ver abajo. |
| `update-service.sh.tftpl` | API, web, worker | Login a ECR, `docker pull <repo>:current` (reintenta hasta 30 min), reemplaza el contenedor, limpia imágenes viejas. |

**Dos momentos distintos de "sustitución":**

1. **En tu PC, al hacer `terraform apply`:** `templatefile()` cambia cada `${nombre}` por su valor.
   Resultado: un script bash normal, con IPs y claves ya escritas.
2. **En la máquina, al arrancar:** bash ejecuta ese script y resuelve `$VARIABLE`, `$1`, etc.

(Por eso `update-service.sh` escribe `$REPOSITORY` sin llaves de Terraform: es para bash.)

**Qué hace `worker.sh.tftpl`** ya rellenado:

1. Pega `common` (Docker, swap, `wait_for`).
2. Escribe `/etc/central/service.conf`: `REPOSITORY=central-worker`, `CONTAINER=central-worker`, `PORTS=""`.
3. Escribe `/etc/central/service.env` (permisos 600): `CENTRAL_DATABASE_URL`, `RABBITMQ_URL`, `INGESTION_QUEUE`.
4. Guarda `/usr/local/bin/update-service.sh`.
5. `wait_for <ip mysql> 3306` y `wait_for <ip rabbitmq> 5672`.
6. Ejecuta `update-service.sh` → baja `central-worker:current` y arranca el contenedor.
7. `log "bootstrap finished OK"`.

### 10.4 Orden en que Terraform crea todo

```
datos (VPC, subredes, AMI, cuenta)
   └─► security groups ─► MySQL, RabbitMQ ─► worker
                     └─► ALB + target groups + listeners
                                 └─► launch templates (api necesita IPs de MySQL/RabbitMQ; web necesita DNS del ALB)
                                         └─► Auto Scaling Groups ─► políticas de CPU
```

### 10.5 Scripts de la infraestructura

- `deploy.sh` (= `make infra`): revisa `terraform` y `aws`, revisa credenciales, crea los repos ECR
  `central-api`, `central-worker`, `central-web` si no existen, `terraform init/plan/apply`, imprime
  las URLs y escribe `.env.cloud`.
- `destroy.sh` (= `make destroy-aws`): `terraform destroy` + borra los 3 repos ECR con sus imágenes.
- `check-comments.sh`: verifica que **cada línea** de código Terraform tenga comentario (requisito
  del curso).

---

## 11. Cómo llega el código a AWS: pipelines, ECR y SSM

Cada carpeta de servicio tiene su `deploy.sh`, como si fuera su propio repositorio con CI:

| Etapa | Qué hace |
|---|---|
| `preflight` | Revisa herramientas, credenciales, que exista el repo ECR y la máquina/grupo destino. |
| `build` | `docker build` para `linux/amd64`, versión `AAAAMMDD-HHMMSS`. |
| `test` | El API corre `pytest` dentro de la imagen. El worker y el web no tienen tests. |
| `push` | Sube la imagen a ECR. |
| `promote` | Mueve la etiqueta **`current`** a la versión nueva (guarda la anterior). |
| `rollout` | API/web: termina sus máquinas; el ASG crea otras que bajan `current`. **Worker:** orden por **SSM** para que su máquina corra `update-service.sh`. |
| `verify` | API: `/health`; web: `/`; worker: por SSM, que el contenedor corra la versión nueva, sin reinicios ni `Traceback`. |
| `rollback` | Si falla rollout/verify: devuelve `current` a la versión anterior. |

Consecuencia: si cambias `worker.py`, basta `make deploy-worker`. `terraform plan` sigue diciendo
**No changes** porque el código no es parte de la infraestructura: solo cambió qué imagen apunta
`current` en ECR.

---

## 12. Tolerancia a fallos: por qué no se pierden ventas

| Falla | Qué pasa |
|---|---|
| Sede central caída | La tienda vende igual; `sync` reintenta; las ventas esperan con `forwarded_at` vacío. |
| Se pierde la respuesta 202 | `sync` reenvía el lote; el worker detecta duplicados (`UNIQUE` + chequeo previo). |
| Worker apagado | Los lotes esperan en RabbitMQ (cola durable, mensajes persistentes en disco). |
| Worker se cae a mitad de un lote | No hubo `ack` → RabbitMQ lo vuelve a entregar; la transacción no confirmada no dejó nada a medias. |
| MySQL caído | El worker hace `nack` y reintenta cada 5 s. |
| RabbitMQ caído | El API responde error y la tienda reintenta; el worker se reconecta solo. |
| Máquina del API enferma | El ALB la detecta y el ASG la reemplaza. |

---

## 13. Comandos `make`

| Comando | Qué hace |
|---|---|
| `make` / `make help` | Lista de comandos. |
| `make up-local` | Todo en tu PC (tiendas + sede + worker). |
| `make up` | `infra` → `deploy-api` → `deploy-worker` → `deploy-web` → `up-stores`. |
| `make infra` | Solo Terraform + repos ECR. |
| `make deploy-api` / `deploy-worker` / `deploy-web` | Solo ese pipeline. |
| `make up-stores` | Solo las tiendas, enviando a AWS (necesita `.env.cloud`). |
| `make ps` | Estado de los contenedores. |
| `make logs CONTAINER=x` | Seguir el log de un contenedor. |
| `make shell CONTAINER=x` | Abrir una terminal dentro de un contenedor. |
| `make test` / `test-unit` / `test-integration` | Pruebas (con el entorno local corriendo). |
| `make down` | Borra todo lo local (contenedores, imágenes, volúmenes). |
| `make destroy-aws` | Borra solo AWS. |
| `make destroy` | Borra AWS y luego lo local. |

---

## 14. Puertos y direcciones

| Qué | Local | AWS |
|---|---|---|
| Cajas tienda 1 / 2 | http://localhost:8081, 8082 / 8083, 8084 | igual (siguen en tu PC) |
| Backend tienda 1 / 2 | http://localhost:18000 / 18001 (`/docs`) | igual |
| PostgreSQL tienda 1 / 2 | `localhost:55432` / `55433` (user/db `store`) | igual |
| Dashboard | http://localhost:8080 | `central_web_url` (ALB puerto 80) |
| API central | http://localhost:18100 (`/docs`) | `central_api_url` (ALB puerto 8000) |
| MySQL central | `localhost:33306` (user/db `central`) | privado: SSH a la máquina o túnel SSH |
| RabbitMQ panel | http://localhost:15672 (`central` / `central_password`) | túnel SSH al 15672 |

---

## 15. Estado del ejercicio

- [x] `central-worker/worker.py` y `models.py` escritos.
- [x] `aws_instance.worker` descomentado con el mapa completo (10 entradas comentadas).
- [x] `outputs.tf` con la IP del worker y `make up` con `$(MAKE) deploy-worker`.
- [x] `check-comments.sh` → OK.
- [x] Preguntas de la sección 6 en `RESPUESTAS.md`.
- [ ] Manual: `terraform validate`, `make up`, capturas y `make destroy` → ver `GUIA-PASO-A-PASO.md`.

Herramientas: `herramientas/Dockerfile` es la imagen del contenedor `aws_dev_environment` (make,
Terraform, AWS CLI, Docker CLI) para la Parte B desde Windows; `herramientas/limpiar-pc.bat` deja el
PC limpio. Ver `GUIA-PASO-A-PASO.md`.

Documentos relacionados: `TERRAFORM-EXPLICADO.md` (cada archivo de Terraform explicado bloque por bloque), `TO-DO.md` (enunciado), `DEPLOY.md` (pipelines),
`infraestructura/HOW-IT-WORKS.md` (código → contenedor en AWS), `README.md` (referencia completa,
en inglés), `GUIA-DE-PRUEBA.pdf` (recorrido con capturas reales).
