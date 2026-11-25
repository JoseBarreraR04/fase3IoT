# Guía paso a paso (sencilla)

Cada bloque dice **dónde** pegarlo:

- **📍 CMD** → el cmd de Windows (Windows + R → `cmd` → Enter).
- **📍 CONTENEDOR** → dentro del contenedor `aws_dev_environment` (la línea se ve `root@xxxx:/app#`).

Antes de todo: abre **Docker Desktop** y espera a que diga **Engine running**.

---

# PARTE A: probar en tu PC (opcional)

📍 **CMD**

```bat
cd C:\Users\JoseB\Desktop\fase3\fase3
if not exist .env copy .env.example .env
docker compose --profile central up -d --build
```

1. Abre **http://localhost:8081** → código `7702001010301` cantidad `2` → Agregar →
   código `7702007000418` cantidad `1` → Agregar → **Pagar**.
2. Espera 1 minuto y mira el log de tu worker:
   📍 **CMD**
   ```bat
   docker logs central-worker
   ```
   Debe decir `lote de store-1 guardado: 1 facturas, 1 nuevas ...`
3. Abre **http://localhost:8080** (dashboard): Tienda 1 con $13.600.

Apagar la Parte A (**obligatorio antes de la B**):
📍 **CMD**
```bat
cd C:\Users\JoseB\Desktop\fase3\fase3
docker compose --profile central down --rmi all -v --remove-orphans
```

---

# PARTE B: AWS

## 1. Launch Learner Lab

1. Abre **https://awsacademy.instructure.com** → **Cursos** → **AWS Academy Learner Lab** →
   **Módulos** → **Launch AWS Academy Learner Lab**.
2. Pulsa **Start Lab** y espera a que el círculo junto a **AWS** esté 🟢 verde.
3. Pulsa **AWS Details** → junto a **SSH key** pulsa **Download PEM** (se guarda `labsuser.pem`
   en Descargas).

## 2. Build docker image + crear el contenedor (solo la primera vez)

📍 **CMD**

```bat
cd C:\Users\JoseB\Desktop\fase3\fase3\herramientas
docker build -t aws_dev_environment_image .
docker rm -f aws_dev_environment
docker run -d --name aws_dev_environment -v C:\Users\JoseB\Desktop\fase3\fase3:/app -v /var/run/docker.sock:/var/run/docker.sock aws_dev_environment_image
docker cp %USERPROFILE%\Downloads\labsuser.pem aws_dev_environment:/root/.ssh/labsuser.pem
```
- El `build` tarda 2–5 minutos la primera vez.
- `docker rm -f` puede decir `No such container`: es normal (solo borra uno viejo si existía).

## 3. Entrar al contenedor

📍 **CMD**

```bat
docker exec -it aws_dev_environment bash
```
La línea cambia a `root@xxxx:/app#`. **Ya estás dentro.** (Para salir: `exit`.)

> Si reiniciaste el PC y dice que el contenedor no está corriendo:
> `docker start aws_dev_environment` y luego otra vez `docker exec -it aws_dev_environment bash`.

## 4. Configure AWS CLI en el contenedor

En el lab: **AWS Details** → **AWS CLI: Show**. Verás:
```
[default]
aws_access_key_id=...
aws_secret_access_key=...
aws_session_token=...
```

**4.1** (solo la primera vez)
📍 **CONTENEDOR**
```bash
aws configure
```
Contesta así (pega cada valor y Enter):
```
AWS Access Key ID:      <pega aws_access_key_id>
AWS Secret Access Key:  <pega aws_secret_access_key>
Default region name:    us-east-1
Default output format:  json
```

**4.2** Pon las credenciales completas (con el token):
📍 **CONTENEDOR**
```bash
nano /root/.aws/credentials
```
- Borra todo lo que haya (mantén **Ctrl + K**).
- Pega el bloque completo del lab, desde `[default]` hasta el final de `aws_session_token`
  (clic derecho o **Ctrl + Shift + V**).
- Guarda: **Ctrl + O**, **Enter**. Sal: **Ctrl + X**.

**4.3** Test:
📍 **CONTENEDOR**
```bash
aws sts get-caller-identity
```
Debe mostrar tu `Account` y `voclabs`. Si dice `ExpiredToken` o `InvalidClientTokenId`, repite 4.2.

> **Cada vez que el lab se reinicia** (Start Lab de nuevo) las credenciales cambian:
> entra al contenedor (paso 3) y repite solo **4.2** y **4.3**.

## 5. Validar Terraform

📍 **CONTENEDOR**

```bash
chmod 400 /root/.ssh/labsuser.pem
cd /app
cp -n .env.example .env
cd /app/infraestructura
terraform init -backend=false
terraform fmt
./check-comments.sh
terraform validate
cd /app
```
Debe decir `OK: todas las líneas de código tienen comentario` y `Success! The configuration is valid`.

## 6. Desplegar todo

📍 **CONTENEDOR**

```bash
cd /app
make up 2>&1 | tee salida-make-up.txt
```
Tarda **15–20 minutos**. Crea todo en AWS, sube tu worker y enciende las tiendas en tu PC.
La salida queda en `salida-make-up.txt` (entregable).

Ver la dirección del dashboard:
📍 **CONTENEDOR**
```bash
cd /app/infraestructura && terraform output central_web_url && cd /app
```

## 7. Probar y sacar capturas 📸

**7.1 Compra.** Abre **http://localhost:8081** → `7702001010301` ×2 y `7702007000418` ×1 → **Pagar**. 📸

**7.2 Venta en la tienda** (📸 ahora; espera 1 minuto y pega otra vez, 📸 con fecha en `forwarded_at`):
📍 **CONTENEDOR**
```bash
docker exec store-1-postgres psql -U store -d store -c "SELECT id, sale_date, total, register_id, forwarded_at FROM sales ORDER BY id;"
```

**7.3 Envío del lote** (📸 de `202 Accepted`):
📍 **CONTENEDOR**
```bash
docker logs store-1-sync 2>&1 | grep -E "Sending|202|received"
```

**7.4 Cola en AWS** (📸, debe salir `invoice-batches 0 1`):
📍 **CONTENEDOR**
```bash
IP=$(aws ec2 describe-instances --filters "Name=tag:Name,Values=central-rabbitmq" "Name=instance-state-name,Values=running" --query "Reservations[].Instances[].PublicIpAddress" --output text)
ssh -o StrictHostKeyChecking=accept-new -i /root/.ssh/labsuser.pem ec2-user@$IP "sudo docker exec central-rabbitmq rabbitmqctl list_queues name messages_ready consumers"
```

**7.5 Log de tu worker en AWS** (📸, debe salir `lote de store-1 guardado ...`):
📍 **CONTENEDOR**
```bash
IP=$(aws ec2 describe-instances --filters "Name=tag:Name,Values=central-worker" "Name=instance-state-name,Values=running" --query "Reservations[].Instances[].PublicIpAddress" --output text)
ssh -o StrictHostKeyChecking=accept-new -i /root/.ssh/labsuser.pem ec2-user@$IP "sudo docker logs central-worker"
```

**7.6 MySQL en AWS** (📸 de `invoices` e `invoice_items`):
📍 **CONTENEDOR**
```bash
IP=$(aws ec2 describe-instances --filters "Name=tag:Name,Values=central-mysql" "Name=instance-state-name,Values=running" --query "Reservations[].Instances[].PublicIpAddress" --output text)
ssh -o StrictHostKeyChecking=accept-new -i /root/.ssh/labsuser.pem ec2-user@$IP "sudo docker exec central-mysql mysql -t -ucentral -pcentral_password central -e 'SELECT * FROM stores; SELECT id, store_id, store_invoice_id, register_id, sold_at, received_at, total FROM invoices; SELECT invoice_id, ean, product_name, quantity, unit_price, subtotal FROM invoice_items;'"
```

**7.7 Dashboard.** Abre la dirección del paso 6 en el navegador. 📸

## 8. Borrar todo en AWS (para no gastar crédito)

📍 **CONTENEDOR**

```bash
cd /app
make destroy
```
Comprobar que no quedó nada (debe salir **vacío**):
📍 **CONTENEDOR**
```bash
aws ec2 describe-instances --filters "Name=tag:Project,Values=d1-chain" "Name=instance-state-name,Values=pending,running,stopping,stopped" --query "Reservations[].Instances[].InstanceId" --output text
```
Salir del contenedor:
📍 **CONTENEDOR**
```bash
exit
```

---

# LIMPIEZA: dejar el PC limpio

Antes: guarda tus capturas y copia `salida-make-up.txt` a otra carpeta. El paso 8 tiene que haber
terminado bien (si no, el limpiador se detiene para que no queden máquinas en AWS).

📍 **CMD**

```bat
cd C:\Users\JoseB\Desktop\fase3\fase3
herramientas\limpiar-pc.bat
```
Escribe `SI` y Enter. Borra los contenedores, imágenes y datos del proyecto, el contenedor
`aws_dev_environment` (con las credenciales que tenía dentro), su imagen, `.env`, los archivos de
Terraform y `labsuser.pem` de Descargas. **No** borra tu código ni los documentos.

Por último, en el lab: **End Lab**.

La próxima vez empiezas otra vez desde **Parte B, paso 1**.

---

## Si algo falla

| Lo que ves | Qué hacer |
|---|---|
| `"make" no se reconoce como un comando` | Lo pegaste en CMD; va en el CONTENEDOR (paso 3). |
| `Conflict. The container name "/aws_dev_environment" is already in use` | Ya lo tienes creado: sáltate el paso 2 y ve al 3. |
| `No such container: aws_dev_environment` | Haz el paso 2. |
| `container ... is not running` | `docker start aws_dev_environment` y repite el paso 3. |
| `ExpiredToken` / `InvalidClientTokenId` / `Unable to locate credentials` | Repite 4.2 y 4.3. |
| `Permission denied (publickey)` | En CMD: `docker cp %USERPROFILE%\Downloads\labsuser.pem aws_dev_environment:/root/.ssh/labsuser.pem`; en el CONTENEDOR: `chmod 400 /root/.ssh/labsuser.pem`. |
| `port is already allocated` | Quedó encendida la Parte A: apágala (final de la Parte A). |
| `Access denied when attempting to assume role ... AWSServiceRoleForAutoScaling` | Pasa la primera vez en una cuenta nueva del lab (AWS crea ese rol y tarda unos minutos). Espera 2–3 minutos y en el CONTENEDOR: `cd /app/infraestructura`, `terraform untaint aws_autoscaling_group.api`, `cd /app`, `make up 2>&1 \| tee salida-make-up.txt`. |
| `make up` falla en `==> [verify]` del worker | Mira 7.5, corrige el código y en el CONTENEDOR: `cd /app` y `make deploy-worker`. |
| La venta no llega a MySQL | Mira 7.4: si dice `consumers 0`, el worker no está corriendo (mira 7.5). |

---

## Entregable

- [ ] `terraform validate` → Success (paso 5)
- [ ] `salida-make-up.txt` (paso 6)
- [ ] 📸 7.1 a 7.7
- [ ] `central-worker/worker.py`, `models.py`, `infraestructura/compute.tf`, `RESPUESTAS.md`
- [ ] `make destroy` (paso 8) y limpieza
