# Terraform explicado a fondo

Este documento explica **cada archivo** de la carpeta `infraestructura/`, **bloque por bloque**,
para que entiendas qué hace cada línea, por qué está ahí y qué pasaría si no estuviera.

## Índice

0. [Lo mínimo que hay que saber de Terraform](#0-lo-mínimo-que-hay-que-saber-de-terraform)
1. [El mapa: qué crea todo esto en AWS](#1-el-mapa-qué-crea-todo-esto-en-aws)
2. [`versions.tf`: la herramienta y el proveedor](#2-versionstf-la-herramienta-y-el-proveedor)
3. [`variables.tf`: las entradas](#3-variablestf-las-entradas)
4. [`network.tf`: la red y los firewalls](#4-networktf-la-red-y-los-firewalls)
5. [`compute.tf`: las máquinas fijas](#5-computetf-las-máquinas-fijas)
6. [`scaling.tf`: las máquinas que escalan](#6-scalingtf-las-máquinas-que-escalan)
7. [`balancer.tf`: la puerta pública](#7-balancertf-la-puerta-pública)
8. [`outputs.tf`: lo que Terraform te devuelve](#8-outputstf-lo-que-terraform-te-devuelve)
9. [`templates/`: los scripts de arranque](#9-templates-los-scripts-de-arranque)
10. [Los scripts: `deploy.sh`, `destroy.sh`, `check-comments.sh`](#10-los-scripts-deploysh-destroysh-check-commentssh)
11. [Archivos que crea Terraform solo](#11-archivos-que-crea-terraform-solo)
12. [En qué orden crea Terraform las cosas](#12-en-qué-orden-crea-terraform-las-cosas)
13. [Qué pasa cuando cambias algo](#13-qué-pasa-cuando-cambias-algo)
14. [Preguntas típicas](#14-preguntas-típicas)

---

## 0. Lo mínimo que hay que saber de Terraform

**Terraform** es un programa que lee archivos `.tf` donde **describes** la infraestructura que
quieres ("quiero 3 máquinas, un firewall y un balanceador") y **la crea** en AWS. Tú no le dices
*cómo* ni *en qué orden*: él lo calcula.

### 0.1 Cómo lee los archivos

- Lee **todos** los `.tf` de la carpeta como si fueran **un solo archivo**. Separarlos en
  `network.tf`, `compute.tf`, etc. es solo para que los humanos lo entiendan. Por eso
  `scaling.tf` puede usar `data.aws_ami.al2023`, que está definido en `compute.tf`.
- El orden de los bloques dentro de los archivos **no importa**.

### 0.2 Los tipos de bloque que aparecen

| Bloque | Qué hace | Cómo se usa después | Ejemplo |
|---|---|---|---|
| `terraform { }` | Configura Terraform mismo (versión, plugins). | — | `versions.tf` |
| `provider "aws" { }` | Configura cómo hablar con AWS. | — | `versions.tf` |
| `variable "x" { }` | Una **entrada** con valor por defecto que puedes cambiar. | `var.x` | `var.region` |
| `locals { }` | Valores **calculados** una vez para reutilizarlos. | `local.x` | `local.registry` |
| `data "tipo" "nombre" { }` | **Lee** algo que ya existe en AWS (no lo crea). | `data.tipo.nombre.atributo` | `data.aws_vpc.default.id` |
| `resource "tipo" "nombre" { }` | **Crea** algo en AWS. | `tipo.nombre.atributo` | `aws_instance.mysql.private_ip` |
| `output "x" { }` | Un valor que Terraform **muestra al final**. | `terraform output x` | `central_web_url` |

> `"tipo"` lo define AWS/Terraform (`aws_instance` = máquina EC2). `"nombre"` lo eliges tú y solo
> sirve dentro de Terraform (no es el nombre en la consola de AWS; ese va en `name` o `tags.Name`).

### 0.3 Sintaxis que vas a ver

| Sintaxis | Significado |
|---|---|
| `clave = valor` | Asignar un valor. |
| `"texto"` | Texto. |
| `"${algo}"` | Meter el valor de `algo` dentro de un texto. Ej.: `"http://${aws_lb.main.dns_name}:8000"`. |
| `[a, b]` | Lista. |
| `{ a = 1, b = 2 }` | Mapa (pares nombre = valor). |
| `bloque { ... }` dentro de otro | Sub‑bloque de configuración (ej. `ingress { }` dentro de un security group). |
| `# texto` | Comentario (el curso exige uno en cada línea). |
| `file(ruta)` | Lee un archivo tal cual. |
| `templatefile(ruta, mapa)` | Lee una plantilla y rellena sus huecos `${...}` con el mapa. |
| `base64encode(texto)` | Codifica un texto en base64. |
| `path.module` | La carpeta donde están los `.tf` (`infraestructura/`). |

### 0.4 Las referencias crean el orden

Si el recurso B usa un atributo del recurso A (`aws_instance.mysql.private_ip`), Terraform sabe
que **A va primero**. Así arma solo un "grafo de dependencias". Ver la sección 12.

### 0.5 Los comandos

| Comando | Qué hace | ¿Toca AWS? |
|---|---|---|
| `terraform init` | Descarga el plugin de AWS a `.terraform/`. | No |
| `terraform fmt` | Ordena espacios y alineación de los `.tf`. | No |
| `terraform validate` | Revisa que la sintaxis y las referencias sean correctas. | No |
| `terraform plan` | Compara lo que dicen los `.tf` con lo que existe y muestra qué cambiaría (`+` crear, `~` modificar, `-` borrar, `-/+` reemplazar). | Solo lee |
| `terraform apply` | Ejecuta el plan: crea, cambia o borra. | **Sí** |
| `terraform output` | Muestra los `output`. | No |
| `terraform destroy` | Borra todo lo que Terraform creó. | **Sí** |
| `terraform untaint X` | Quita la marca de "dañado" a un recurso para que no se reemplace. | No |

### 0.6 El estado (`terraform.tfstate`)

Después de un `apply`, Terraform guarda en `terraform.tfstate` **qué creó** y sus datos (IDs,
IPs…). Es su memoria: así sabe en el siguiente `plan` qué ya existe. **Si lo borras, Terraform
olvida todo lo que creó** (las máquinas siguen en AWS pero él ya no las puede borrar). Por eso
`make destroy` va antes de cualquier limpieza.

---

## 1. El mapa: qué crea todo esto en AWS

```
                               INTERNET
             (tu navegador)                 (las tiendas en tu PC)
                   │ puerto 80                      │ puerto 8000
                   ▼                                ▼
          ┌──────────────────────────────────────────────────┐
          │   aws_lb.main  "central-alb"  (balanceador)      │  firewall: aws_security_group.alb
          │   listener :80 ──► target group web              │
          │   listener :8000 ─► target group api             │
          └──────────┬───────────────────────────┬───────────┘
                     │                           │
        ┌────────────▼──────────┐   ┌────────────▼───────────┐
        │ ASG central-web (1–2) │   │ ASG central-api (1–2)  │   scaling.tf
        │ máquinas del dashboard│   │ máquinas del API       │
        │ firewall: sg web      │   │ firewall: sg api       │
        └───────────────────────┘   └───────┬─────────┬──────┘
                                            │ 3306    │ 5672
         ┌──────────────────────────────────▼──┐  ┌───▼──────────────────────┐
         │ aws_instance.mysql   (MySQL)        │  │ aws_instance.rabbitmq    │   compute.tf
         │ firewall: sg mysql                  │  │ firewall: sg rabbitmq    │
         └──────────────────────────────────▲──┘  └───▲──────────────────────┘
                                            │ 3306    │ 5672
                                    ┌───────┴─────────┴──────┐
                                    │ aws_instance.worker    │   compute.tf
                                    │ firewall: sg worker    │
                                    └────────────────────────┘
   Todo dentro de la VPC por defecto de la cuenta (network.tf).
   Las imágenes Docker vienen de ECR (lo crea deploy.sh, no Terraform).
```

| Archivo | Qué aporta |
|---|---|
| `versions.tf` | Versión de Terraform, plugin de AWS, región, etiqueta común. |
| `variables.tf` | Las 13 entradas configurables. |
| `network.tf` | Busca la red por defecto y crea 6 firewalls. |
| `compute.tf` | Busca la imagen de Linux, calcula valores comunes y crea MySQL, RabbitMQ y el worker. |
| `scaling.tf` | Recetas y grupos de escalado del API y del dashboard, y sus reglas de CPU. |
| `balancer.tf` | El balanceador, sus 2 grupos de destino y sus 2 puertas (listeners). |
| `outputs.tf` | Las URLs, el registro ECR y las IPs. |
| `templates/` | Los scripts bash que cada máquina corre al encender. |

**En total Terraform crea 20 recursos:** 6 security groups, 3 instancias, 2 launch templates,
2 auto scaling groups, 2 políticas de escalado, 1 balanceador, 2 target groups y 2 listeners
(y lee 5 `data`).

---

## 2. `versions.tf`: la herramienta y el proveedor

```hcl
terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}
```

| Línea | Qué significa |
|---|---|
| `terraform {` | Bloque de configuración de Terraform mismo. |
| `required_version = ">= 1.5"` | Si tu `terraform` es más viejo que 1.5, se niega a correr (el contenedor trae 1.9.8). |
| `required_providers {` | Lista de plugins ("providers") que hacen falta. Terraform no sabe hablar con AWS por sí solo: lo hace un plugin. |
| `aws = {` | El plugin se llamará `aws` en este código. |
| `source = "hashicorp/aws"` | Se descarga del registro público de Terraform, publicado por HashiCorp. |
| `version = "~> 6.0"` | Cualquier `6.x` (6.0, 6.71…), pero **nunca** 7.0. `~>` = "compatible con". Evita que una versión nueva rompa el código. La versión exacta que se usó queda en `.terraform.lock.hcl` (6.71.0). |

```hcl
provider "aws" {
  region = var.region
  default_tags {
    tags = {
      Project = "d1-chain"
    }
  }
}
```

| Línea | Qué significa |
|---|---|
| `provider "aws" {` | Configuración del plugin de AWS. |
| `region = var.region` | Todo se crea en la región de la variable `region` (`us-east-1`). Las credenciales **no** van aquí: el plugin las lee solo de `~/.aws/credentials`. |
| `default_tags { tags = { Project = "d1-chain" } }` | Pone la etiqueta `Project = d1-chain` a **todo** lo que cree, sin repetirla en cada recurso. Gracias a eso puedes buscar "todo lo del proyecto" con `aws ec2 describe-instances --filters Name=tag:Project,Values=d1-chain`. |

---

## 3. `variables.tf`: las entradas

Cada variable tiene la misma forma:

```hcl
variable "region" {
  description = "Region de AWS (el Learner Lab permite us-east-1)"
  type        = string
  default     = "us-east-1"
}
```

| Campo | Qué significa |
|---|---|
| `variable "region"` | Crea la entrada `region`; en el código se usa como `var.region`. |
| `description` | Texto de ayuda (sale si Terraform pregunta por ella). |
| `type` | `string` = texto, `number` = número. Si le das otro tipo, Terraform da error. |
| `default` | Valor que se usa si no das otro. Como **todas** tienen default, `terraform apply` no pregunta nada. |
| `sensitive = true` | (solo en claves) Terraform muestra `(sensitive value)` en vez del valor en `plan`/`apply`. Ojo: sigue quedando en `terraform.tfstate` y en el `user_data`. |

### Las 13 variables

| Variable | Tipo | Default | Dónde se usa | Para qué |
|---|---|---|---|---|
| `region` | string | `us-east-1` | `versions.tf`, `compute.tf` | Región de AWS. El Learner Lab solo permite us-east-1 y us-west-2. |
| `instance_type` | string | `t3.micro` | todas las máquinas, `network.tf` | Tamaño de máquina: 2 vCPU, 1 GB RAM. |
| `max_instances` | number | `2` | `scaling.tf` | Máximo de máquinas en cada grupo de escalado. |
| `key_name` | string | `vockey` | todas las máquinas | Par de llaves SSH que ya trae el lab; su parte privada es `labsuser.pem`. |
| `instance_profile` | string | `LabInstanceProfile` | todas las máquinas | Rol IAM que el lab ya trae. Da permiso a la máquina para bajar imágenes de ECR y recibir órdenes de SSM **sin** guardar credenciales en ella. |
| `ssh_cidr` | string | `0.0.0.0/0` | `network.tf` | Desde qué IPs se permite SSH. `0.0.0.0/0` = desde cualquier lugar (aceptable en clase). |
| `mysql_root_password` | string, sensitive | `central_root_password` | `compute.tf` (mysql) | Clave del administrador de MySQL. |
| `mysql_database` | string | `central` | mysql, api, worker | Nombre de la base de datos. |
| `mysql_user` | string | `central` | mysql, api, worker | Usuario de la aplicación en MySQL. |
| `mysql_password` | string, sensitive | `central_password` | mysql, api, worker | Su clave. |
| `rabbitmq_user` | string | `central` | rabbitmq, api, worker | Usuario de RabbitMQ. |
| `rabbitmq_password` | string, sensitive | `central_password` | rabbitmq, api, worker | Su clave. |
| `ingestion_queue` | string | `invoice-batches` | api, worker | Nombre de la cola entre el API y el worker. |

**Cómo cambiar una:** copia `terraform.tfvars.example` a `terraform.tfvars` y descomenta la línea
(ej. `instance_type = "t3.small"`). Terraform lee `terraform.tfvars` solo.

---

## 4. `network.tf`: la red y los firewalls

### 4.1 Buscar la red por defecto (3 bloques `data`)

```hcl
data "aws_vpc" "default" {
  default = true
}
```
Una **VPC** es una red privada dentro de AWS. Toda cuenta trae una "por defecto". Este bloque
**no crea** nada: la **busca** y guarda su ID en `data.aws_vpc.default.id`. Así no hay que crear
una red desde cero.

```hcl
data "aws_ec2_instance_type_offerings" "available" {
  location_type = "availability-zone"
  filter {
    name   = "instance-type"
    values = [var.instance_type]
  }
}
```
Pregunta a AWS: **"¿en qué zonas existe la máquina `t3.micro`?"**. Una región (us-east-1) tiene
varias **zonas de disponibilidad** (us-east-1a, 1b, … 1f), que son centros de datos separados.
Algunas (como `us-east-1e`) **no** tienen `t3.micro`; si Terraform intentara crear una máquina
ahí, fallaría. La respuesta queda en `.locations` (lista de zonas válidas).

```hcl
data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
  filter {
    name   = "availability-zone"
    values = data.aws_ec2_instance_type_offerings.available.locations
  }
}
```
Una **subred** es un pedazo de la VPC que vive en **una** zona. Este bloque busca las subredes que
cumplen **dos** filtros a la vez: que sean de la VPC por defecto **y** que estén en una zona que
tenga `t3.micro`. El resultado (`data.aws_subnets.default.ids`) lo usan el balanceador y los
grupos de escalado para saber **dónde** pueden poner cosas.

### 4.2 Qué es un security group

Un **security group** es un **firewall** que se pega a una máquina (o al balanceador). Por defecto
**no deja entrar nada**; cada `ingress` abre una puerta:

| Campo | Qué significa |
|---|---|
| `ingress { }` | Regla de **entrada** (lo que puede llegar). |
| `egress { }` | Regla de **salida** (a dónde puede conectarse la máquina). |
| `from_port` / `to_port` | Rango de puertos. `80` a `80` = solo el 80. |
| `protocol = "tcp"` | Tipo de tráfico. `"-1"` = todos. |
| `cidr_blocks = ["0.0.0.0/0"]` | Desde/hacia **qué IPs**. `0.0.0.0/0` = cualquier IP de internet. |
| `security_groups = [aws_security_group.alb.id]` | Desde **qué otros firewalls**: "solo máquinas que tengan puesto ese security group". |
| `vpc_id` | En qué red se crea. |
| `name` / `description` | Lo que ves en la consola. (La descripción va sin tildes porque AWS no las acepta ahí.) |

> **Por qué usar `security_groups` y no IPs:** las máquinas del API las crea y destruye el grupo
> de escalado, y cada una tiene una IP distinta. Decir "cualquiera con el firewall `api`" funciona
> siempre, sin importar cuántas haya ni qué IP tengan.

Todos los grupos tienen el mismo `egress` (salida libre): las máquinas necesitan salir a internet
para instalar Docker, bajar imágenes de ECR, hablar con SSM y conectarse entre ellas.

### 4.3 Los 6 security groups

#### `aws_security_group.alb` — el del balanceador
| Regla | Puerto | Desde | Por qué |
|---|---|---|---|
| ingress "Dashboard" | 80 | `0.0.0.0/0` | Cualquier navegador puede ver el dashboard. |
| ingress "API central" | 8000 | `0.0.0.0/0` | Las tiendas envían sus lotes; no sabemos sus IPs públicas. |
| egress | todo | todo | Para reenviar el tráfico a las máquinas de atrás. |

Es la **única puerta pública** del sistema.

#### `aws_security_group.web` — el del dashboard
| Regla | Puerto | Desde | Por qué |
|---|---|---|---|
| ingress "HTTP desde el balanceador" | 80 | sg `alb` | Solo el balanceador puede hablarle. Nadie de internet entra directo. |
| ingress "SSH" | 22 | `var.ssh_cidr` | Para entrar por consola a revisar. |

#### `aws_security_group.api` — el del API
| Regla | Puerto | Desde | Por qué |
|---|---|---|---|
| ingress "API desde el balanceador" | 8000 | sg `alb` | Solo el balanceador. |
| ingress "SSH" | 22 | `var.ssh_cidr` | Revisar. |

#### `aws_security_group.worker` — el del worker
| Regla | Puerto | Desde | Por qué |
|---|---|---|---|
| ingress "SSH" | 22 | `var.ssh_cidr` | **Es lo único que entra.** El worker no recibe conexiones: él **se conecta** a RabbitMQ y MySQL (eso es salida, y la salida está libre). |

Este grupo existe aunque solo tenga SSH porque **MySQL y RabbitMQ lo nombran** como origen
permitido. Sin él, no habría forma de decir "deja entrar al worker".

#### `aws_security_group.rabbitmq` — el de la cola
| Regla | Puerto | Desde | Por qué |
|---|---|---|---|
| ingress "AMQP" | 5672 | sg `api` **y** sg `worker` | El API publica lotes y el worker los consume. Nadie más. |
| ingress "SSH" | 22 | `var.ssh_cidr` | Revisar (`rabbitmqctl`). |

El panel web (15672) **no** está abierto: solo se ve con un túnel SSH.

#### `aws_security_group.mysql` — el de la base de datos
| Regla | Puerto | Desde | Por qué |
|---|---|---|---|
| ingress "MySQL" | 3306 | sg `api` **y** sg `worker` | El worker escribe facturas y el API lee reportes. Nadie más. |
| ingress "SSH" | 22 | `var.ssh_cidr` | Revisar. |

**Resumen de quién llega a quién:**
```
internet ─80/8000─► alb ─80─► web
                       └─8000─► api ─5672─► rabbitmq ◄─5672─ worker
                                    └─3306─► mysql    ◄─3306─ worker
```

---

## 5. `compute.tf`: las máquinas fijas

### 5.1 La imagen del sistema operativo

```hcl
data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]
  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-x86_64"]
  }
}
```
Una **AMI** es la "imagen de disco" con la que arranca una máquina (como un ISO de instalación).

| Línea | Qué significa |
|---|---|
| `owners = ["amazon"]` | Solo imágenes publicadas por Amazon (no de terceros desconocidos). |
| `values = ["al2023-ami-2023.*-x86_64"]` | Nombre con comodín `*`: **Amazon Linux 2023**, para procesadores Intel/AMD de 64 bits. |
| `most_recent = true` | Si hay varias, la más nueva (con parches de seguridad). |

Se busca en vez de escribir un ID fijo (`ami-0abc…`) porque los IDs cambian por región y con cada
actualización. Se usa como `data.aws_ami.al2023.id`.

### 5.2 El número de cuenta

```hcl
data "aws_caller_identity" "current" {}
```
Pregunta a AWS **"¿quién soy?"** y devuelve el número de cuenta (`account_id`, ej. `707905938407`).
Hace falta para armar la dirección del registro de imágenes ECR, que incluye ese número.

### 5.3 `locals`: valores calculados

```hcl
locals {
  registry      = "${data.aws_caller_identity.current.account_id}.dkr.ecr.${var.region}.amazonaws.com"
  common_script = file("${path.module}/templates/common.sh.tftpl")
  update_script = templatefile("${path.module}/templates/update-service.sh.tftpl", {
    registry = local.registry
    region   = var.region
  })
}
```

| Local | Valor | Para qué |
|---|---|---|
| `registry` | `707905938407.dkr.ecr.us-east-1.amazonaws.com` | Dirección del registro ECR de **tu** cuenta. Las máquinas bajan de ahí `central-api:current`, etc. |
| `common_script` | El texto de `common.sh.tftpl` **tal cual** (`file()` no rellena nada) | Los primeros pasos que hacen todas las máquinas (swap, Docker, `wait_for`). Se pega dentro de cada plantilla. |
| `update_script` | `update-service.sh.tftpl` con `${registry}` y `${region}` ya rellenados | El script que baja la imagen `current` y arranca el contenedor. Lo usan API, web y worker. |

Se calculan **una vez** y se reutilizan en 5 lugares: si cambia algo, se cambia en un solo sitio.

### 5.4 `aws_instance.mysql` — la máquina de la base de datos

```hcl
resource "aws_instance" "mysql" {
  ami                    = data.aws_ami.al2023.id
  instance_type          = var.instance_type
  key_name               = var.key_name
  iam_instance_profile   = var.instance_profile
  vpc_security_group_ids = [aws_security_group.mysql.id]

  root_block_device {
    volume_size = 16
  }

  user_data = templatefile("${path.module}/templates/mysql.sh.tftpl", {
    common        = local.common_script
    schema_sql    = file("${path.module}/../central-db/01-schema.sql")
    seed_sql      = file("${path.module}/../central-db/02-seed.sql")
    root_password = var.mysql_root_password
    database      = var.mysql_database
    db_user       = var.mysql_user
    db_password   = var.mysql_password
  })

  lifecycle {
    ignore_changes = [user_data]
  }

  tags = {
    Name = "central-mysql"
  }
}
```

| Línea | Qué significa |
|---|---|
| `resource "aws_instance" "mysql"` | Crea **una** máquina EC2. En Terraform se llama `aws_instance.mysql`. |
| `ami` | Arranca con Amazon Linux 2023 (5.1). |
| `instance_type` | `t3.micro`. |
| `key_name` | Recibe la llave `vockey`: puedes entrar con `labsuser.pem`. |
| `iam_instance_profile` | Recibe el rol `LabInstanceProfile` (permite SSM). |
| `vpc_security_group_ids` | Se le pone el firewall `mysql` (4.3). Es una lista: una máquina puede tener varios. |
| `root_block_device { volume_size = 16 }` | Disco de 16 GB (el default de 8 GB se llena con Docker + datos). |
| `user_data = templatefile(...)` | El **script que la máquina corre una sola vez al primer arranque** (sección 9). `templatefile` rellena los huecos de `mysql.sh.tftpl` con el mapa. Nota: `schema_sql` y `seed_sql` usan `file()` para **incrustar** los `.sql` de `central-db/` dentro del script; así la máquina no necesita descargarlos de ningún lado. |
| `lifecycle { ignore_changes = [user_data] }` | **Clave.** Normalmente, si cambia el `user_data`, AWS tiene que reemplazar la máquina. Aquí se le dice a Terraform que **ignore** esos cambios: la máquina de la base de datos **nunca se reemplaza**, porque perdería todas las facturas guardadas. |
| `tags = { Name = "central-mysql" }` | El nombre que ves en la consola y que usan los comandos `aws ec2 describe-instances --filters Name=tag:Name,...`. (`Project` lo agrega `default_tags`.) |

Atributos que **otros** usan de esta máquina: `aws_instance.mysql.private_ip` (API y worker) y
`.public_ip` (outputs).

### 5.5 `aws_instance.rabbitmq` — la máquina de la cola

Igual que MySQL, con estas diferencias:

| Línea | Valor | Por qué |
|---|---|---|
| `vpc_security_group_ids` | `[aws_security_group.rabbitmq.id]` | Su propio firewall (5672 solo para api y worker). |
| `user_data` | `rabbitmq.sh.tftpl` con `common`, `rabbitmq_user`, `rabbitmq_password` | Solo necesita crear el usuario de la cola. |
| `lifecycle { ignore_changes = [user_data] }` | igual | **Nunca se reemplaza**: guarda en disco los lotes que todavía no consumió el worker. |
| `tags.Name` | `central-rabbitmq` | |

### 5.6 `aws_instance.worker` — la máquina del worker (lo del ejercicio)

```hcl
resource "aws_instance" "worker" {
  ami                    = data.aws_ami.al2023.id
  instance_type          = var.instance_type
  key_name               = var.key_name
  iam_instance_profile   = var.instance_profile
  vpc_security_group_ids = [aws_security_group.worker.id]

  root_block_device {
    volume_size = 16
  }

  user_data = templatefile("${path.module}/templates/worker.sh.tftpl", {
    common            = local.common_script
    update_script     = local.update_script
    mysql_ip          = aws_instance.mysql.private_ip
    rabbitmq_ip       = aws_instance.rabbitmq.private_ip
    database          = var.mysql_database
    db_user           = var.mysql_user
    db_password       = var.mysql_password
    rabbitmq_user     = var.rabbitmq_user
    rabbitmq_password = var.rabbitmq_password
    queue             = var.ingestion_queue
  })
  user_data_replace_on_change = true

  tags = {
    Name = "central-worker"
  }
}
```

Las primeras líneas son iguales a MySQL (imagen, tamaño, llave, rol, disco), con el firewall
`worker`. Lo importante es **el mapa** de `templatefile`: tiene **una entrada por cada `${...}`**
de `worker.sh.tftpl`. Si falta una, Terraform da el error
`vars map does not contain key "..."`.

| Entrada del mapa | Valor | De dónde sale | Qué hace en la máquina |
|---|---|---|---|
| `common` | `local.common_script` | local (5.3) | Instala swap, Docker y `wait_for`. |
| `update_script` | `local.update_script` | local (5.3) | Se guarda como `/usr/local/bin/update-service.sh`. |
| `mysql_ip` | `aws_instance.mysql.private_ip` | **atributo de otra máquina** | IP privada de MySQL, para `CENTRAL_DATABASE_URL` y para esperar el puerto 3306. |
| `rabbitmq_ip` | `aws_instance.rabbitmq.private_ip` | **atributo de otra máquina** | IP privada de RabbitMQ, para `RABBITMQ_URL` y esperar el 5672. |
| `database` | `var.mysql_database` | variable | Nombre de la base (`central`). |
| `db_user` | `var.mysql_user` | variable | Usuario MySQL. |
| `db_password` | `var.mysql_password` | variable | Clave MySQL. |
| `rabbitmq_user` | `var.rabbitmq_user` | variable | Usuario RabbitMQ. |
| `rabbitmq_password` | `var.rabbitmq_password` | variable | Clave RabbitMQ. |
| `queue` | `var.ingestion_queue` | variable | `INGESTION_QUEUE=invoice-batches`. |

**Por qué IP privada y no pública:** dentro de la VPC las máquinas se hablan por la red privada
(más rápida, gratis y no pasa por internet). Además los firewalls de MySQL/RabbitMQ solo aceptan
tráfico que venga de máquinas con el sg `worker`/`api`, y eso solo se cumple por la red privada.

**Por qué referencias y no IPs escritas a mano:** las IPs no se conocen hasta que AWS crea las
máquinas. Con la referencia, Terraform (1) crea primero MySQL y RabbitMQ, (2) lee sus IPs y
(3) recién ahí arma el script del worker. Y si MySQL se reemplazara, la IP nueva llegaría sola.

| Línea | Qué significa |
|---|---|
| `user_data_replace_on_change = true` | Lo **contrario** de MySQL: si el script de arranque cambia (por ejemplo cambia la IP de MySQL o una clave), Terraform **crea un worker nuevo** para que arranque con la configuración nueva. El worker no guarda datos, así que reemplazarlo no pierde nada. |
| `tags.Name = "central-worker"` | Además del nombre en la consola, **lo usa `central-worker/deploy.sh`** para encontrar la máquina y mandarle la orden de actualizar por SSM. |

> **Ojo:** el **código** del worker (`worker.py`) **no** está aquí. Terraform solo prepara la
> máquina. El código llega como imagen Docker por ECR (sección 13).

---

## 6. `scaling.tf`: las máquinas que escalan

El API y el dashboard **no** se crean con `aws_instance`. Los crea un **Auto Scaling Group (ASG)**,
que mantiene viva la cantidad de máquinas que se le pida y las reemplaza si se enferman. El ASG
necesita una **receta** para fabricarlas: la **launch template**.

> **¿Por qué no todo con `aws_instance`?** MySQL, RabbitMQ y el worker son **uno solo** cada uno
> (guardan datos o deben ser un único consumidor). El API y el dashboard **no guardan nada**:
> pueden ser 1 o 2 copias idénticas detrás del balanceador, y si una se muere da igual, se crea
> otra. Eso es justo lo que hace un ASG.

### 6.1 `aws_launch_template.api` — la receta de una máquina del API

```hcl
resource "aws_launch_template" "api" {
  name_prefix            = "central-api-"
  image_id               = data.aws_ami.al2023.id
  instance_type          = var.instance_type
  key_name               = var.key_name
  vpc_security_group_ids = [aws_security_group.api.id]

  iam_instance_profile {
    name = var.instance_profile
  }

  block_device_mappings {
    device_name = "/dev/xvda"
    ebs {
      volume_size = 16
    }
  }

  user_data = base64encode(templatefile("${path.module}/templates/api.sh.tftpl", { ...mapa... }))

  tag_specifications {
    resource_type = "instance"
    tags = {
      Name    = "central-api"
      Project = "d1-chain"
    }
  }
}
```

Es como un `aws_instance` **que todavía no nació**: describe cómo será cada máquina, pero no crea
ninguna. Comparación:

| En `aws_instance` | En `aws_launch_template` | Diferencia |
|---|---|---|
| `ami` | `image_id` | Solo cambia el nombre del campo. |
| `iam_instance_profile = "..."` | `iam_instance_profile { name = "..." }` | Aquí es un sub‑bloque. |
| `root_block_device { volume_size = 16 }` | `block_device_mappings { device_name = "/dev/xvda"  ebs { volume_size = 16 } }` | Hay que nombrar el disco: `/dev/xvda` es el disco raíz de Amazon Linux. |
| `user_data = templatefile(...)` | `user_data = base64encode(templatefile(...))` | Las launch templates **exigen** el script en base64. |
| `tags = {...}` | `tag_specifications { resource_type = "instance" tags = {...} }` | Las etiquetas son para las máquinas que se creen; `default_tags` no llega a ellas, por eso `Project` se repite aquí. |
| — | `name_prefix = "central-api-"` | AWS le agrega un sufijo aleatorio (`central-api-2026...`). Así Terraform puede crear una nueva antes de borrar la vieja. |

**El mapa del API es idéntico al del worker** (mismas 10 entradas: `common`, `update_script`,
`mysql_ip`, `rabbitmq_ip`, `database`, `db_user`, `db_password`, `rabbitmq_user`,
`rabbitmq_password`, `queue`), porque el API también habla con MySQL (reportes) y con RabbitMQ
(publicar lotes). Por eso el TO-DO decía "guíate por `scaling.tf`".

### 6.2 `aws_launch_template.web` — la receta del dashboard

Igual al del API, pero con el firewall `web` y un mapa más corto:

| Entrada | Valor | Para qué |
|---|---|---|
| `common` | `local.common_script` | Pasos comunes. |
| `update_script` | `local.update_script` | Bajar y arrancar `central-web:current`. |
| `api_host` | `aws_lb.main.dns_name` | El dashboard (nginx) reenvía las peticiones `/api/...` al **balanceador**, puerto 8000. Así el navegador habla con un solo origen. |

Fíjate: el dashboard **no** conoce MySQL ni RabbitMQ; solo habla con el API a través del
balanceador. Esto crea una dependencia: el balanceador se crea **antes** que esta receta.

### 6.3 `aws_autoscaling_group.api` — el grupo del API

```hcl
resource "aws_autoscaling_group" "api" {
  name                      = "central-api"
  min_size                  = 1
  desired_capacity          = 1
  max_size                  = var.max_instances
  vpc_zone_identifier       = data.aws_subnets.default.ids
  target_group_arns         = [aws_lb_target_group.api.arn]
  health_check_type         = "ELB"
  health_check_grace_period = 300

  launch_template {
    id      = aws_launch_template.api.id
    version = aws_launch_template.api.latest_version
  }

  tag {
    key                 = "Project"
    value               = "d1-chain"
    propagate_at_launch = false
  }

  lifecycle {
    ignore_changes = [desired_capacity]
  }
}
```

| Línea | Qué significa |
|---|---|
| `name = "central-api"` | Nombre en la consola. Lo usa `central-api/deploy.sh` para encontrar el grupo. |
| `min_size = 1` | Nunca menos de 1 máquina: si se muere, crea otra. |
| `desired_capacity = 1` | Cuántas quiere tener **ahora**. Empieza con 1. |
| `max_size = var.max_instances` | Nunca más de 2, aunque la CPU explote. |
| `vpc_zone_identifier` | En qué subredes (zonas) puede crear máquinas (4.1). Si hay varias, las reparte. |
| `target_group_arns = [aws_lb_target_group.api.arn]` | Cada máquina que cree la **registra sola** en el grupo de destino del API del balanceador (7.2). Así el balanceador sabe a quién mandarle tráfico. |
| `health_check_type = "ELB"` | Para decidir si una máquina está sana, usa el chequeo **del balanceador** (`GET /health`), no solo "está encendida". Si el API se cuelga, el ASG la reemplaza. |
| `health_check_grace_period = 300` | Espera 5 minutos antes de evaluar a una máquina nueva: necesita tiempo para instalar Docker y bajar la imagen. Sin esto, la mataría por "enferma" mientras arranca. |
| `launch_template { id = ... version = ...latest_version }` | Qué receta usar, y **siempre su última versión** (si cambias la receta, las máquinas nuevas usan la nueva). |
| `tag { key = "Project" ... propagate_at_launch = false }` | Etiqueta al **grupo** mismo. `false`: no se la copia a las máquinas, porque ellas ya la reciben de la launch template. |
| `lifecycle { ignore_changes = [desired_capacity] }` | Si la carga subió y AWS puso `desired_capacity = 2`, un `terraform apply` posterior **no** lo devuelve a 1. |

> **El error que te salió** (`Access denied ... AWSServiceRoleForAutoScaling`) ocurre en este
> bloque: para validar `target_group_arns`, el ASG usa un rol interno de AWS que se crea la
> primera vez que una cuenta usa Auto Scaling y tarda unos minutos en activarse. Terraform marcó
> el grupo como *tainted* (dañado) y por eso se usó `terraform untaint`.

### 6.4 `aws_autoscaling_group.web` — el grupo del dashboard

Idéntico al del API, pero con `name = "central-web"`, el target group `web` y la launch template
`web`.

### 6.5 `aws_autoscaling_policy.api_cpu` y `.web_cpu` — cuándo escalar

```hcl
resource "aws_autoscaling_policy" "api_cpu" {
  name                   = "central-api-cpu"
  autoscaling_group_name = aws_autoscaling_group.api.name
  policy_type            = "TargetTrackingScaling"

  target_tracking_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ASGAverageCPUUtilization"
    }
    target_value = 60
  }
}
```

| Línea | Qué significa |
|---|---|
| `autoscaling_group_name` | A qué grupo controla. |
| `policy_type = "TargetTrackingScaling"` | "Mantén esta métrica cerca de este valor". Es como un termostato: tú pones la meta y AWS decide cuándo agregar o quitar máquinas. |
| `predefined_metric_type = "ASGAverageCPUUtilization"` | La métrica: **CPU promedio** de las máquinas del grupo. |
| `target_value = 60` | La meta: 60 %. Si la CPU promedio pasa de 60 %, sube `desired_capacity` (hasta `max_size` = 2). Si baja bastante, la reduce (hasta `min_size` = 1). |

`web_cpu` es igual para el grupo del dashboard.

---

## 7. `balancer.tf`: la puerta pública

Un **Application Load Balancer (ALB)** recibe todo el tráfico de internet y lo reparte entre las
máquinas sanas. Tiene 3 piezas:

```
 listener (puerto)  ──►  target group (grupo de máquinas + chequeo de salud)  ──►  máquinas
```

### 7.1 `aws_lb.main` — el balanceador

```hcl
resource "aws_lb" "main" {
  name               = "central-alb"
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = data.aws_subnets.default.ids
}
```

| Línea | Qué significa |
|---|---|
| `name` | Nombre en la consola; también aparece en su dirección (`central-alb-XXXX.us-east-1.elb.amazonaws.com`). |
| `load_balancer_type = "application"` | Balanceador de capa 7: entiende HTTP (rutas, códigos de respuesta). |
| `security_groups` | Su firewall: 80 y 8000 abiertos a internet (4.3). |
| `subnets` | Se reparte en varias zonas (AWS exige al menos 2). Si una zona falla, sigue funcionando. |

Su atributo `dns_name` es la **dirección pública estable** del sistema (no cambia aunque las
máquinas cambien).

### 7.2 `aws_lb_target_group.api` y `.web` — los grupos de destino

```hcl
resource "aws_lb_target_group" "api" {
  name                 = "central-api"
  port                 = 8000
  protocol             = "HTTP"
  vpc_id               = data.aws_vpc.default.id
  deregistration_delay = 30

  health_check {
    path                = "/health"
    healthy_threshold   = 2
    unhealthy_threshold = 3
    interval            = 15
  }
}
```

| Línea | Qué significa |
|---|---|
| `port = 8000` | A qué puerto de **cada máquina** se manda el tráfico (el contenedor del API escucha en 8000). |
| `protocol = "HTTP"` | HTTP simple entre balanceador y máquinas. |
| `vpc_id` | En qué red están las máquinas. |
| `deregistration_delay = 30` | Cuando una máquina sale del grupo, el balanceador le da 30 s para terminar las peticiones en curso (en vez de 300 s por defecto: los despliegues son más rápidos). |
| `health_check { path = "/health" }` | Cada `interval = 15` segundos el balanceador pide `GET /health` a cada máquina. |
| `healthy_threshold = 2` | 2 respuestas buenas seguidas → **sana** (empieza a recibir tráfico). |
| `unhealthy_threshold = 3` | 3 fallos seguidos → **enferma** (deja de recibir tráfico y el ASG la reemplaza). |

El de `web` es igual, con `port = 80` y `path = "/"` (la página del dashboard).

Las máquinas **no** se agregan aquí a mano: las registra el ASG gracias a `target_group_arns`.

### 7.3 `aws_lb_listener.web` y `.api` — las puertas

```hcl
resource "aws_lb_listener" "web" {
  load_balancer_arn = aws_lb.main.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.web.arn
  }
}
```

| Línea | Qué significa |
|---|---|
| `load_balancer_arn` | A qué balanceador pertenece. (Un **ARN** es el identificador único de cualquier cosa en AWS.) |
| `port = 80` | El balanceador escucha en el puerto 80. |
| `default_action { type = "forward" target_group_arn = ... }` | Todo lo que llegue se **reenvía** al target group `web`. |

`aws_lb_listener.api` es igual con `port = 8000` → target group `api`.

**Resultado:** `http://central-alb-XXXX...` → dashboard; `http://central-alb-XXXX...:8000` → API.

---

## 8. `outputs.tf`: lo que Terraform te devuelve

| Output | Valor | Quién lo usa |
|---|---|---|
| `central_api_url` | `"http://${aws_lb.main.dns_name}:8000"` | `deploy.sh` lo escribe en `.env.cloud` como `CENTRAL_API_PUBLIC_URL`: así las **tiendas** saben a dónde mandar los lotes. |
| `central_web_url` | `"http://${aws_lb.main.dns_name}"` | Tú, para abrir el dashboard. |
| `ecr_registry` | `local.registry` | Los pipelines de servicio, para saber a dónde subir las imágenes. |
| `ssh_addresses` | mapa `{ mysql, rabbitmq, worker }` con sus `public_ip` | Tú, para entrar por SSH. **Ojo:** si el lab se apaga y enciende, las IPs públicas cambian y este output queda viejo hasta el próximo `apply`; por eso la guía las busca con `aws ec2 describe-instances`. |

Cada output tiene `description` (texto de ayuda) y `value`. Se ven con `terraform output` o uno
solo con `terraform output -raw central_web_url`.

---

## 9. `templates/`: los scripts de arranque

### 9.1 Qué es `user_data` y qué es una plantilla `.tftpl`

- **`user_data`** = un script bash que AWS le entrega a una máquina nueva y que ella ejecuta **una
  sola vez**, en su **primer arranque**, como root. Es cómo una máquina vacía se convierte en
  "la máquina de MySQL".
- **`.tftpl`** = plantilla de Terraform: un script con **huecos** `${nombre}`.

**Dos momentos distintos:**

| Momento | Dónde | Quién | Qué reemplaza |
|---|---|---|---|
| 1. `terraform apply` | tu PC (el contenedor) | `templatefile()` de Terraform | `${mysql_ip}`, `${db_password}`, `${common}`… por sus valores reales. Sale un script bash normal. |
| 2. Primer arranque | la máquina en AWS | bash | `$REPOSITORY`, `$1`, `$(date)`… (variables de bash, **sin llaves**). |

Por eso en las plantillas verás `${...}` (Terraform) y `$ALGO` (bash) mezclados.

### 9.2 `common.sh.tftpl` — lo que hacen todas las máquinas

Se lee con `file()` (no tiene huecos) y se inserta en `${common}` al inicio de cada plantilla.

| Paso | Qué hace | Por qué |
|---|---|---|
| `set -euo pipefail` | Si un comando falla, el script se detiene. | Que un error no pase desapercibido. |
| `exec > >(tee -a /var/log/central-bootstrap.log) 2>&1` | Copia toda la salida a `/var/log/central-bootstrap.log`. | Para revisar qué pasó al arrancar. |
| `log() { ... }` | Función que imprime con fecha y hora. | Mensajes legibles. |
| `dd ... /swapfile`, `mkswap`, `swapon` | Crea 1 GB de **swap** (memoria en disco). | `t3.micro` tiene solo 1 GB de RAM; MySQL y RabbitMQ la agotarían. |
| `dnf install -y docker nmap-ncat` | Instala Docker y netcat. | Todo corre en contenedores; netcat prueba puertos. |
| `systemctl enable --now docker` | Arranca Docker ahora y en cada encendido. | |
| `wait_for HOST PUERTO` | Función: reintenta cada 5 s (hasta ~15 min) hasta que ese puerto responda. | El API y el worker no deben arrancar antes que MySQL y RabbitMQ. |

### 9.3 `mysql.sh.tftpl`

| Hueco | Viene de |
|---|---|
| `${common}`, `${schema_sql}`, `${seed_sql}`, `${root_password}`, `${database}`, `${db_user}`, `${db_password}` | El mapa de `aws_instance.mysql` (5.4). |

Qué hace: escribe `01-schema.sql` y `02-seed.sql` en `/opt/central-db/`, y arranca el contenedor
`mysql:8.4` con: las claves, el puerto 3306, un **volumen** `mysql-data` (los datos sobreviven si
el contenedor se reinicia), la carpeta de scripts montada en `/docker-entrypoint-initdb.d` (MySQL
los ejecuta solo la primera vez: crea las tablas y las 2 tiendas) y poca memoria
(`--innodb-buffer-pool-size=128M`). `--restart unless-stopped`: si la máquina se reinicia, MySQL
vuelve solo.

### 9.4 `rabbitmq.sh.tftpl`

Arranca `rabbitmq:3.13-management-alpine` con: usuario y clave, puerto 5672 abierto, panel web
15672 **solo en localhost** (se ve con túnel SSH), nombre de host fijo (RabbitMQ guarda los datos
con el nombre del host; si cambiara, "perdería" la cola) y volumen `rabbitmq-data`.

### 9.5 `api.sh.tftpl` y `worker.sh.tftpl` (casi iguales)

1. `${common}`.
2. Escribe `/etc/central/service.conf`: `REPOSITORY` (qué imagen de ECR), `CONTAINER` (nombre del
   contenedor) y `PORTS` (`-p 8000:8000` en el API; **vacío** en el worker, que no recibe
   conexiones).
3. Escribe `/etc/central/service.env` con las variables que lee el programa:
   `CENTRAL_DATABASE_URL=mysql+pymysql://usuario:clave@IP_MYSQL:3306/central`,
   `RABBITMQ_URL=amqp://usuario:clave@IP_RABBITMQ:5672/%2F` (`%2F` = el "vhost" `/`) e
   `INGESTION_QUEUE`. `chmod 600`: solo root lo lee (tiene claves).
4. Guarda `${update_script}` en `/usr/local/bin/update-service.sh`.
5. `wait_for IP_MYSQL 3306` y `wait_for IP_RABBITMQ 5672`.
6. Ejecuta `update-service.sh` → baja la imagen y arranca el contenedor.
7. `log "bootstrap finished OK"` (lo buscan las verificaciones).

### 9.6 `web.sh.tftpl`

Igual estructura, con `PORTS="-p 80:80"` y `service.env` con
`CENTRAL_API_UPSTREAM=${api_host}:8000` (a dónde manda nginx las peticiones `/api`). No espera a
nadie.

### 9.7 `update-service.sh.tftpl` — cómo llega el código

Huecos de Terraform: `${registry}` y `${region}` (5.3). Lo demás es bash.

1. Lee `service.conf` (`REPOSITORY`, `CONTAINER`, `PORTS`).
2. `IMAGE="<registry>/$REPOSITORY:current"`.
3. Hasta 120 intentos cada 15 s (30 min): login a ECR con el rol de la máquina y `docker pull`.
   (En el primer despliegue la máquina existe **antes** que la imagen: espera a que el pipeline la
   suba.)
4. `docker rm -f` del contenedor viejo y `docker run -d --restart unless-stopped --env-file service.env $PORTS $IMAGE`.
5. `docker image prune -f` para no llenar el disco.

Lo corre el arranque la primera vez y, en el worker, **SSM lo vuelve a correr** en cada
`make deploy-worker`.

---

## 10. Los scripts: `deploy.sh`, `destroy.sh`, `check-comments.sh`

### `deploy.sh` (= `make infra`)

| Etapa | Qué hace |
|---|---|
| `[preflight]` | Revisa que existan `terraform` y `aws`, y que las credenciales funcionen (`aws sts get-caller-identity`). |
| `[registry]` | Crea los repositorios ECR `central-api`, `central-worker`, `central-web` si no existen (`MUTABLE`: la etiqueta `current` se puede mover). **Terraform no los crea**: así `destroy` de Terraform no borra imágenes por accidente. |
| `[plan]` | `terraform init` y `terraform plan -out=tfplan` (guarda el plan). |
| `[apply]` | `terraform apply tfplan` (aplica exactamente ese plan, sin preguntar). |
| final | Lee `central_api_url` y escribe `.env.cloud` para las tiendas; imprime las URLs. |

### `destroy.sh` (= `make destroy-aws`, parte de `make destroy`)

Revisa herramientas y credenciales; si existe `terraform.tfstate`, corre `terraform destroy
-auto-approve`; borra los 3 repositorios ECR con sus imágenes (`--force`); borra `.env.cloud`.

### `check-comments.sh`

Con `awk` recorre `*.tf`, `*.sh`, `templates/*.tftpl` y los `deploy.sh` de los servicios, y lista
toda línea de código sin `#`. Ignora líneas vacías, el shebang `#!`, líneas que solo cierran
bloques (`}`, `fi`, `done`…) y los finales de heredoc (`SQL`, `SCRIPT`). Es la regla del curso:
"cada línea lleva su comentario".

---

## 11. Archivos que crea Terraform solo

| Archivo | Qué es | ¿Se sube a git? |
|---|---|---|
| `.terraform/` | El plugin de AWS descargado por `terraform init`. | No (`.gitignore`). |
| `.terraform.lock.hcl` | La versión **exacta** del plugin usada (6.71.0) y sus firmas. Así todos usan la misma. | **Sí.** |
| `terraform.tfstate` | La memoria de Terraform: qué creó, con IDs, IPs y **claves**. | No. |
| `terraform.tfstate.backup` | El estado anterior. | No. |
| `tfplan` | Plan guardado entre `plan` y `apply` (se borra después). | No. |
| `terraform.tfvars` | Tus valores propios para las variables (opcional). | No. |

---

## 12. En qué orden crea Terraform las cosas

Terraform sigue las referencias. Lo que no depende entre sí se crea **en paralelo**.

```
 data: aws_vpc ─► aws_ec2_instance_type_offerings ─► aws_subnets
 data: aws_ami, aws_caller_identity ─► locals (registry, update_script)
          │
          ▼
 security groups:  alb ─► web, api ;  worker ;  api + worker ─► rabbitmq, mysql
          │
          ├─► aws_instance.mysql ─────┐
          ├─► aws_instance.rabbitmq ──┼─► aws_instance.worker        (necesita sus private_ip)
          │                           └─► aws_launch_template.api    (necesita sus private_ip)
          │
          └─► aws_lb.main ─► aws_lb_target_group.api/web ─► aws_lb_listener.api/web
                   └────────► aws_launch_template.web                (necesita dns_name)

 launch_template.api + target_group.api ─► aws_autoscaling_group.api ─► aws_autoscaling_policy.api_cpu
 launch_template.web + target_group.web ─► aws_autoscaling_group.web ─► aws_autoscaling_policy.web_cpu
```

`terraform destroy` lo hace **al revés** (primero las políticas y grupos, al final los firewalls).

---

## 13. Qué pasa cuando cambias algo

| Cambias… | `terraform plan` dice | Qué pasa en AWS |
|---|---|---|
| `worker.py` y corres `make deploy-worker` | `No changes` | Nada de infraestructura. Se sube una imagen nueva a ECR, se mueve la etiqueta `current` y SSM ejecuta `update-service.sh` en la máquina del worker. **El código no es infraestructura.** |
| Una regla de un security group | `~ update in-place` | Se modifica el firewall sin tocar las máquinas. |
| `instance_type` | Reemplazos y cambios | Worker: `-/+` (se recrea). Launch templates: nueva versión; las máquinas nuevas del ASG la usan. MySQL/RabbitMQ: se cambia el tamaño (se apagan y encienden), pero **no** se reemplazan. |
| `mysql_password` | Worker `-/+`; launch template API `~` | El worker se recrea con la clave nueva (`user_data_replace_on_change`). MySQL **ignora** el cambio (`ignore_changes`): la clave real de la base **no** cambia → habría que cambiarla a mano. |
| `max_instances` | `~ update in-place` | Los ASG aceptan hasta ese número. |
| Borras `terraform.tfstate` | `+ create` de todo | Terraform cree que no existe nada e intentaría crear duplicados (y fallaría por nombres repetidos). **No lo hagas.** |

---

## 14. Preguntas típicas

**¿Por qué el worker no tiene un puerto abierto?**
Porque nadie se conecta a él. El worker **abre** conexiones hacia RabbitMQ y MySQL (salida). Un
firewall solo necesita abrir puertos para conexiones **entrantes**.

**¿Por qué MySQL no se reemplaza nunca y el worker sí?**
MySQL guarda datos (las facturas) en su disco: reemplazarlo los borraría. El worker no guarda nada:
si se reemplaza, el nuevo lee la cola desde donde quedó.

**¿Por qué el API y el dashboard usan ASG y el worker no?**
El API y el dashboard están detrás de un balanceador y son intercambiables (pueden ser 1 o 2). El
worker es un solo consumidor de la cola (en este proyecto) y no recibe tráfico del balanceador.

**¿Qué pasaría si escribo la IP de MySQL a mano en el mapa del worker?**
Funcionaría hasta que MySQL cambiara de IP (por ejemplo si se recreara). Entonces el worker
quedaría esperando en `wait_for IP_VIEJA 3306` para siempre y la cola se llenaría. Con la
referencia, Terraform pone la IP correcta solo.

**¿Por qué `${...}` lo resuelve Terraform y `$REPOSITORY` bash?**
Porque `templatefile()` corre en tu PC al hacer `apply` y solo reemplaza `${...}`. El resultado
viaja a la máquina como `user_data`, y ahí bash ejecuta el script y resuelve sus propias variables.

**¿Las claves quedan seguras?**
Para clase sí; en la vida real no: aparecen en el `user_data` (visible en la consola de AWS) y en
`terraform.tfstate`. En producción se usarían AWS Secrets Manager o SSM Parameter Store.

**¿Dónde veo lo que pasó en una máquina?**
`/var/log/central-bootstrap.log` (primer arranque, debe terminar en `bootstrap finished OK`),
`/var/log/central-update.log` (cada despliegue) y `sudo docker logs <contenedor>`.
