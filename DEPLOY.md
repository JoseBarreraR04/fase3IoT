# Cómo se despliega la sede central en AWS

La sede central se despliega con **cuatro pipelines**, uno por carpeta. Cada carpeta se
comporta como si fuera **su propio repositorio** con su propio GitHub Actions: tiene su
`deploy.sh`, no importa nada de las otras y se puede desplegar sola. Por eso hay código
repetido entre ellos, a propósito.

| Pipeline | Qué despliega | Cómo llega a las máquinas |
|---|---|---|
| `infraestructura/deploy.sh` | Red, firewalls, balanceador, máquinas y repositorios de imágenes (ECR). **Nada de código.** | Terraform |
| `central-api/deploy.sh` | El API central | Imagen en ECR + terminar las máquinas del grupo para que lleguen otras nuevas |
| `central-worker/deploy.sh` | El worker | Imagen en ECR + orden por SSM a su única máquina |
| `central-web/deploy.sh` | El dashboard | Imagen en ECR + terminar las máquinas del grupo para que lleguen otras nuevas |

---

## 1. Requisitos

- Una sesión activa del **AWS Academy Learner Lab**, con las credenciales de *AWS Details*
  copiadas en `~/.aws/credentials`. Caducan: repite esto cada vez que inicies el lab.
- Instalados: Docker, Terraform 1.5 o más, AWS CLI v2 y `curl`.
- `cp .env.example .env` (lo usan las tiendas locales).

---

## 2. El orden, y por qué

```
1. infraestructura/deploy.sh   crea las máquinas y los repositorios ECR; escribe .env.cloud
2. central-api/deploy.sh       sube la imagen del API
3. central-worker/deploy.sh    sube la imagen del worker
4. central-web/deploy.sh       sube la imagen del dashboard
5. make up-stores              arranca las tiendas en este computador, apuntando al balanceador
```

- **La infraestructura va primero** porque los pipelines de servicio suben imágenes a
  repositorios ECR y actualizan máquinas que ella crea. Si no existen, cada pipeline se
  detiene en su etapa `preflight` con un mensaje que lo dice.
- **Los tres servicios pueden ir en cualquier orden** entre sí. Recién creadas, las
  máquinas esperan (hasta 30 minutos) a que aparezca su imagen `current` en ECR y la bajan
  solas. Mientras tanto el sistema está incompleto: por ejemplo, sin worker los lotes se
  acumulan en la cola sin perderse.
- **Las tiendas van al final** porque leen la dirección del balanceador de `.env.cloud`.

`make up` corre los cinco pasos en ese orden y se detiene en el primero que falle.

---

## 3. Comandos

| Comando | Qué hace |
|---|---|
| `make up` | Todo, en el orden de la sección 2 |
| `make infra` | Solo `infraestructura/deploy.sh` |
| `make deploy-api` | Solo `central-api/deploy.sh` |
| `make deploy-worker` | Solo `central-worker/deploy.sh` |
| `make deploy-web` | Solo `central-web/deploy.sh` |
| `make up-stores` | Solo las tiendas locales |
| `make destroy` | `infraestructura/destroy.sh` (máquinas, balanceador, red y repositorios con sus imágenes) y luego `make down` (todo lo local). Si el paso de AWS falla, no borra nada local |
| `make destroy-aws` | Solo la parte de AWS |
| `make down` | Solo la limpieza local |

Cada `deploy.sh` también se puede correr directamente, desde cualquier carpeta:
`./central-api/deploy.sh`.

---

## 4. Las etapas de un pipeline de servicio

Cada pipeline imprime una línea `==> [etapa]` al empezar cada etapa, para que se vea dónde
va y dónde falló.

| Etapa | Qué hace |
|---|---|
| `preflight` | Revisa herramientas, credenciales, que exista el repositorio ECR y la máquina o el grupo de destino |
| `build` | Construye la imagen para `linux/amd64` y le pone una versión `AAAAMMDD-HHMMSS` (hora UTC) |
| `test` | El API corre sus pruebas `pytest` dentro de la imagen; si fallan, nada llega a AWS. El worker y el dashboard no tienen pruebas y lo dicen |
| `push` | Sube la imagen a ECR con su versión |
| `promote` | Mueve la etiqueta `current` a la versión nueva. Antes guarda cuál era la anterior. Si la imagen es idéntica a la que ya corre, termina sin tocar nada |
| `rollout` | API y dashboard: termina las máquinas del grupo. El grupo debe tener 1 máquina, así que crea otra que baja `current` al arrancar. El servicio no responde por unos 3 a 5 minutos (ver nota abajo). Worker: orden por SSM para que su máquina baje `current` y cambie el contenedor. En el primer despliegue no hace falta: las máquinas ya esperan la imagen |
| `verify` | API: `GET /health` por el balanceador. Dashboard: `GET /`. Worker: por SSM, que el contenedor corra la imagen nueva, sin reinicios ni errores en el log |
| `rollback` | Solo si `rollout` o `verify` fallan: devuelve `current` a la versión anterior, repite el `rollout` y termina con error |

**Nota sobre el corte.** Mientras el API se reemplaza, no responde. Las tiendas no pierden
ventas: las guardan y reintentan. Despliegues sin corte (*zero downtime*, alta
disponibilidad) son tema de otro laboratorio. AWS ofrece *instance refresh* para eso, pero
el Learner Lab no lo permite.

Cómo sabe cada máquina qué correr: en el arranque, Terraform le deja el script
`/usr/local/bin/update-service.sh`, que entra a ECR, baja `REPOSITORIO:current` y
reemplaza el contenedor. Las máquinas nuevas lo corren al arrancar; la del worker lo vuelve
a correr cada vez que SSM se lo pide.

---

## 5. Situaciones comunes

**Cambié el código del API.** Corre solo `make deploy-api`. El worker y el dashboard no se
tocan, y `terraform plan` en `infraestructura/` sigue sin cambios: el código ya no es
parte de la infraestructura.

**Cambié la infraestructura** (un firewall, el tamaño de las máquinas). Corre `make infra`.
Muestra el plan y lo aplica. Las máquinas nuevas bajan la imagen `current` que ya existe.

**Desplegué una versión rota.** Si no pasa `verify` (que espera hasta 10 minutos a las máquinas nuevas), el pipeline vuelve solo a la versión
anterior. Para volver a una versión vieja a mano, busca su etiqueta con
`aws ecr list-images --repository-name central-api` y corrige el código; cada despliegue
es una versión nueva.

**Un pipeline dice que no hay credenciales.** Cópialas otra vez del Learner Lab.

**Algo falla en una máquina.** El arranque escribe en `/var/log/central-bootstrap.log` y
cada actualización en `/var/log/central-update.log`. Cómo entrar por SSH: sección 8 del
`README.md`.

**Terminé.** `make destroy`. Los recursos gastan crédito del lab mientras existan.
