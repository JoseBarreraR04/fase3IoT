# Guía paso a paso: cómo probar el proyecto (Docker local y AWS)

Hay **dos formas** de probarlo. Haz primero la A (más fácil, sin AWS) y después la B (la que
pide el entregable).

| | Parte A: todo local | Parte B: sede central en AWS |
|---|---|---|
| Dónde corre la sede central | Contenedores en tu PC | Máquinas EC2 en AWS |
| Dónde corren las tiendas | Contenedores en tu PC | Contenedores en tu PC |
| Necesita AWS | No | Sí (Learner Lab) |
| Comando principal | `make up-local` | `make up` |
| Sirve para | Comprobar que tu worker funciona | El entregable (capturas y salida de `make up`) |

---

## 0. Conceptos mínimos

- **Docker:** empaqueta un programa con todo lo que necesita en una **imagen**. Cuando la
  ejecutas se llama **contenedor**. Cada servicio del proyecto (caja, backend, worker, MySQL…) es
  un contenedor.
- **Docker Compose (`docker-compose.yml`):** archivo que describe los 20 contenedores, sus redes y
  sus variables. `docker compose up` los levanta todos.
- **`make`:** atajos. `make up-local` es lo mismo que escribir
  `docker compose --profile central up -d --build`. Los atajos están en el `Makefile`.
- **AWS Learner Lab:** una cuenta temporal de AWS del curso. Al darle *Start Lab* te da unas
  credenciales que **caducan** cuando se acaba la sesión.
- **Terraform:** crea la infraestructura de AWS (máquinas, red, balanceador) leyendo los
  archivos `.tf`. `terraform apply` = "crea lo que dicen los archivos".
- **ECR:** el "Docker Hub" privado de tu cuenta AWS. Los pipelines suben ahí las imágenes y las
  máquinas las bajan de ahí.
- **`aws_dev_environment`:** el contenedor del curso que ya trae `make`, `terraform`, `aws` y
  `docker`. **Tu Windows no tiene `make`, `terraform` ni `aws` instalados**, así que la Parte B
  se hace dentro de ese contenedor.

---

## 1. ¿Dónde escribo los comandos?

| Parte | Dónde | Por qué |
|---|---|---|
| A (local) | **PowerShell** o Git Bash de Windows, en la carpeta del proyecto, con Docker Desktop abierto | Solo necesitas Docker. Si no tienes `make`, usa los comandos `docker compose` de la columna de al lado |
| B (AWS) | **Dentro del contenedor `aws_dev_environment`**, en la carpeta del proyecto | Necesitas `make`, `terraform` y `aws` |

> En este PC no existe todavía un contenedor `aws_dev_environment`. Créalo/ábrelo como te lo
> indicó el curso (normalmente se monta la carpeta del proyecto en `/app`). Desde ese contenedor
> también se maneja el Docker de tu PC, así que las tiendas igual corren en Docker Desktop.

---

## PARTE A: probar todo en tu computador (Docker)

### A1. Preparar

1. Abre **Docker Desktop** y espera a que diga *Engine running*.
2. Abre PowerShell en la carpeta del proyecto:
   ```powershell
   cd C:\Users\JoseB\Desktop\fase3\fase3
   ```
3. Crea el archivo de configuración (solo la primera vez):
   ```powershell
   copy .env.example .env
   ```
4. (Opcional, recomendado) Para no esperar 60 s a que salga cada lote, abre `.env` y cambia:
   ```
   BATCH_MAX_AGE_SECONDS=10
   ```

### A2. Levantar todo

| Con make | Sin make (PowerShell) |
|---|---|
| `make up-local` | `docker compose --profile central up -d --build` |
| `make ps` | `docker compose --profile central ps` |

La primera vez tarda varios minutos (construye imágenes e inicia 3 bases de datos). Cuando
`ps` muestre todo en `running` / `healthy`, sigue.

### A3. Mirar el log del worker (déjalo abierto en otra ventana)

| Con make | Sin make |
|---|---|
| `make logs CONTAINER=central-worker` | `docker compose --profile central logs -f central-worker` |

Al arrancar debe decir:
```
... INFO [central-worker] conectado a MySQL
... INFO [central-worker] esperando lotes en la cola 'invoice-batches'
```
(Para salir del log: `Ctrl + C`; el contenedor sigue corriendo.)

### A4. Hacer una compra

1. Abre **http://localhost:8081** (caja 1 de la tienda 1).
2. Escribe el código `7702001010301` (Arroz Diana 500g), cantidad `2`, **Agregar**.
3. Escribe `7702007000418` (Frijol Cargamanto 500g), cantidad `1`, **Agregar**.
4. **Pagar**. Anota el número de venta.

### A5. Ver la venta en la tienda (PostgreSQL)

```powershell
docker exec -it store-1-postgres psql -U store -d store
```
Dentro de `psql`:
```sql
SELECT id, sale_date, total, register_id, forwarded_at FROM sales ORDER BY id;
\q
```
Primero `forwarded_at` está vacío; tras el envío del lote (10–60 s) aparece con fecha.

### A6. Ver el envío del lote

```powershell
docker compose --profile central logs -f store-1-sync
```
Busca `"HTTP/1.1 202 Accepted"` y `marked forwarded`.

### A7. Ver que el worker lo guardó

En la ventana del log del worker (paso A3) debe aparecer:
```
... INFO [central-worker] lote de store-1 guardado: 1 facturas, 1 nuevas, 0 duplicadas, 0 inválidas
```

> La guía PDF muestra otro texto (`Batch from store-1: 1 saved…`) porque usa el worker de
> ejemplo del profesor. El tuyo escribe en español; lo importante es que diga "guardado".

### A8. Ver la cola en RabbitMQ (opcional)

Abre **http://localhost:15672** (usuario `central`, clave `central_password`) → pestaña
*Queues* → `invoice-batches`: **Ready 0** y **Consumers 1**.

### A9. Ver la factura en MySQL central

```powershell
docker exec -it central-mysql mysql -ucentral -pcentral_password central
```
```sql
SELECT id, store_id, store_invoice_id, register_id, sold_at, received_at, total FROM invoices;
SELECT invoice_id, ean, product_name, quantity, unit_price, subtotal FROM invoice_items;
exit
```

### A10. Ver el dashboard

- Dashboard: **http://localhost:8080** (se refresca cada 10 s).
- API directo: http://localhost:18100/reports/sales-by-store y http://localhost:18100/docs

Si la venta aparece en los 6 lugares, **tu worker funciona**.

### A11. Pruebas extra (opcionales)

- **Worker apagado no pierde ventas:**
  ```powershell
  docker stop central-worker      # apaga el worker
  # haz 2 o 3 compras en http://localhost:8081, espera el envío
  # en http://localhost:15672 verás mensajes en Ready y 0 consumidores
  docker start central-worker     # lo prendes: vacía la cola y guarda todo
  ```
- **Pruebas automáticas:** `make test` (o mira el `Makefile` para los comandos equivalentes).

### A12. Apagar lo local (OBLIGATORIO antes de la Parte B)

| Con make | Sin make |
|---|---|
| `make down` | `docker compose --profile central down --rmi all -v --remove-orphans` |

Borra contenedores, imágenes y **volúmenes** (las bases vuelven a empezar vacías). Si no lo
haces, en la Parte B chocan los puertos y queda un worker local consumiendo.

---

## PARTE B: desplegar la sede central en AWS

Tiempo: 15–20 min la primera vez. Todo **dentro de `aws_dev_environment`**.

### B1. Arrancar el Learner Lab

1. Entra a AWS Academy → tu curso → *Learner Lab* → **Start Lab**.
2. Espera a que el círculo junto a "AWS" esté **verde**.

### B2. Copiar las credenciales al contenedor

1. En el Learner Lab: **AWS Details** → *AWS CLI* → **Show**. Copia todo el bloque
   (`[default]`, `aws_access_key_id`, `aws_secret_access_key`, `aws_session_token`).
2. Dentro del contenedor:
   ```bash
   mkdir -p ~/.aws
   nano ~/.aws/credentials      # pega el bloque, guarda con Ctrl+O, Enter, sale con Ctrl+X
   ```
3. Comprueba:
   ```bash
   aws sts get-caller-identity   # debe mostrar tu número de cuenta, no un error
   ```
> Caducan a las pocas horas. Si un comando dice que no hay credenciales, repite B2.

### B3. Copiar la llave SSH (para entrar a las máquinas después)

1. En el Learner Lab: **AWS Details** → **Download PEM** (`labsuser.pem`).
2. Guárdala en la carpeta del proyecto y dentro del contenedor:
   ```bash
   mkdir -p ~/.ssh
   cp /app/labsuser.pem ~/.ssh/labsuser.pem      # ajusta la ruta a donde la guardaste
   chmod 400 ~/.ssh/labsuser.pem
   ```
   (No la subas a git: es una clave privada.)

### B4. Validar Terraform

```bash
cd /app                              # carpeta del proyecto dentro del contenedor (ajústala)
cp .env.example .env                 # si no existe
cd infraestructura
terraform init -backend=false        # solo la primera vez
terraform fmt
./check-comments.sh                  # OK: todas las líneas de código tienen comentario
terraform validate                   # Success! The configuration is valid
cd ..
```

### B5. Desplegar todo (y guardar la salida para el entregable)

```bash
make up 2>&1 | tee salida-make-up.txt
```

Verás estas etapas, en orden:

| Etapa | Qué pasa |
|---|---|
| `make infra` | Crea repos ECR y corre `terraform apply` (red, firewalls, balanceador, MySQL, RabbitMQ, worker, grupos del API y dashboard). Imprime las URLs y escribe `.env.cloud`. |
| `make deploy-api` | Construye la imagen del API, corre sus tests, la sube a ECR, reemplaza las máquinas, revisa `/health`. |
| `make deploy-worker` | Construye **tu worker**, lo sube a ECR, lo actualiza por SSM y revisa que no se reinicie ni tenga `Traceback`. |
| `make deploy-web` | Igual con el dashboard. |
| `make up-stores` | Levanta las 2 tiendas en tu PC, apuntando al balanceador de AWS. |

Cada etapa imprime `==> [preflight]`, `==> [build]`, `==> [push]`, `==> [verify]`… Si una
falla, `make up` se detiene ahí: lee el mensaje de esa etapa.

Anota las dos URLs que imprime `make infra`:
```
Dashboard: http://central-alb-XXXX.us-east-1.elb.amazonaws.com
API:       http://central-alb-XXXX.us-east-1.elb.amazonaws.com:8000
```
(Para verlas otra vez: `cd infraestructura && terraform output`.)

### B6. Conseguir las IPs públicas de las máquinas

```bash
F="Name=tag:Project,Values=d1-chain Name=instance-state-name,Values=running"
Q='Reservations[].Instances[].[Tags[?Key==`Name`]|[0].Value,PublicIpAddress]'
aws ec2 describe-instances --filters $F --query "$Q" --output text
```
Te da `central-mysql`, `central-rabbitmq`, `central-worker`, `central-api`, `central-web` con su IP.

### B7. Recorrer la compra (los 6 pasos de `GUIA-DE-PRUEBA.pdf`), con captura en cada uno

**Paso 1 – Compra:** http://localhost:8081 → agrega `7702001010301` ×2 y `7702007000418` ×1 → Pagar. 📸

**Paso 2 – PostgreSQL de la tienda:**
```bash
docker exec -it store-1-postgres psql -U store -d store
SELECT id, sale_date, total, register_id, forwarded_at FROM sales ORDER BY id;
```
📸 con `forwarded_at` vacío. Espera ~60 s, repite la consulta. 📸 con fecha. `\q` para salir.

**Paso 3 – Envío del lote:**
```bash
make logs CONTAINER=store-1-sync
```
📸 de la línea `POST http://central-alb-...:8000/sales/batch "HTTP/1.1 202 Accepted"`.

**Paso 4 – Cola y worker:**
```bash
ssh -i ~/.ssh/labsuser.pem ec2-user@<IP de central-rabbitmq>
sudo docker exec central-rabbitmq rabbitmqctl list_queues name messages_ready consumers
exit
```
Debe dar `invoice-batches 0 1`. 📸
```bash
ssh -i ~/.ssh/labsuser.pem ec2-user@<IP de central-worker>
sudo docker logs central-worker
exit
```
Debe mostrar `lote de store-1 guardado: ... 1 nuevas ...`. 📸

**Paso 5 – MySQL en AWS:**
```bash
ssh -i ~/.ssh/labsuser.pem ec2-user@<IP de central-mysql>
sudo docker exec -it central-mysql mysql -ucentral -pcentral_password central
SELECT * FROM stores;
SELECT id, store_id, store_invoice_id, register_id, sold_at, received_at, total FROM invoices;
SELECT invoice_id, ean, product_name, quantity, unit_price, subtotal FROM invoice_items;
exit
exit
```
📸 de `invoices` e `invoice_items`.

**Paso 6 – Dashboard:** abre la URL del dashboard (B5). 📸 Opcional:
```bash
curl http://<URL del dashboard>/api/reports/sales-by-store
```

### B8. Apagar AWS al terminar (no gastes crédito)

```bash
make destroy
```
Borra todo en AWS (máquinas, balanceador, ECR) y luego todo lo local.

---

## 2. Si algo falla

| Síntoma | Causa probable / qué hacer |
|---|---|
| `make: command not found` en PowerShell | Normal en Windows. Usa los comandos `docker compose` de la Parte A, o el contenedor `aws_dev_environment`. |
| `port is already allocated` | Otro contenedor usa el puerto. `make down` (o `docker compose --profile central down`) y vuelve a levantar. |
| Error de credenciales en cualquier `deploy.sh` | Caducaron. Repite B2. |
| `make up` falla en `==> [verify]` del worker | El contenedor se cae. En la máquina: `sudo docker logs central-worker`. Corrige, prueba con Parte A y corre solo `make deploy-worker`. |
| Arranque del worker se queda en `esperando a ...:3306` | La máquina no llega a MySQL. Mira `/var/log/central-bootstrap.log` en la máquina del worker. |
| `forwarded_at` sigue vacío tras 2 min | La tienda no llega al API: `make logs CONTAINER=store-1-sync` y revisa `.env.cloud`. |
| La tienda recibe `202` pero MySQL no cambia | Nadie consume la cola (`consumers = 0`): el worker no está corriendo. |
| `Permission denied (publickey)` / `UNPROTECTED PRIVATE KEY FILE` | La llave no está en `~/.ssh` del contenedor o le falta `chmod 400`. Usuario: `ec2-user`. |
| SSH no conecta | El lab se reinició y cambiaron las IPs: repite B6. |
| La caja da error al agregar producto | Base de la tienda vacía: `make down` y `make up-stores`. |

Logs útiles en las máquinas de AWS:

- `/var/log/central-bootstrap.log` → primer arranque (debe terminar en `bootstrap finished OK`).
- `/var/log/central-update.log` → cada despliegue.
- `sudo docker logs central-worker` → tu código.

---

## 3. Lista del entregable

- [ ] Parte A probada (venta llega al dashboard local).
- [ ] `terraform validate` → `Success!`
- [ ] `salida-make-up.txt` (salida de `make up`).
- [ ] 📸 PostgreSQL de la tienda (sin y con `forwarded_at`).
- [ ] 📸 Log de `store-1-sync` con `202 Accepted`.
- [ ] 📸 Cola `invoice-batches 0 1`.
- [ ] 📸 Log de tu worker guardando el lote.
- [ ] 📸 MySQL en AWS: `invoices` e `invoice_items`.
- [ ] 📸 Dashboard con la venta.
- [ ] `central-worker/worker.py`, `models.py`, `infraestructura/compute.tf` y `RESPUESTAS.md`.
- [ ] `make destroy` al terminar.
