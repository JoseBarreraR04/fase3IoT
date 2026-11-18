#!/usr/bin/env bash
# Pipeline del worker: construye la imagen, la sube a ECR, la promueve a "current" y le pide a su máquina, por SSM, que la use.
# Es independiente de los demás: imagina que esta carpeta es su propio repositorio con su propio GitHub Actions.
set -euo pipefail                                        # Detenerse ante el primer error, variable sin definir o tubería fallida
cd "$(dirname "$0")"                                     # Trabajar desde la carpeta del servicio, sin importar desde dónde se llame
SERVICE="central-worker"                                 # Nombre del servicio, del repositorio ECR, del contenedor y de la etiqueta Name de la máquina
REGION="us-east-1"                                       # Región donde vive la infraestructura

echo "==> [preflight] revisando herramientas, credenciales e infraestructura" # Etapa 1: comprobar que se puede desplegar
for tool in docker aws; do                               # Programas que necesita este pipeline
  if ! command -v "$tool" >/dev/null 2>&1; then          # ¿Está instalado?
    echo "Error: falta el programa '$tool'." >&2         # Decir cuál falta
    exit 1                                               # Detenerse antes de hacer nada
  fi
done
if ! ACCOUNT="$(aws sts get-caller-identity --query Account --output text 2>/dev/null)"; then # Preguntar a AWS el número de cuenta; falla si no hay credenciales
  echo "Error: las credenciales de AWS faltan o caducaron. Cópialas del Learner Lab." >&2 # Explicar el problema
  exit 1                                                 # Detenerse
fi
REGISTRY="$ACCOUNT.dkr.ecr.$REGION.amazonaws.com"        # Dirección del registro ECR de la cuenta
if ! aws ecr describe-repositories --region "$REGION" --repository-names "$SERVICE" >/dev/null 2>&1; then # ¿Existe el repositorio de imágenes?
  echo "Error: no existe el repositorio ECR $SERVICE. Corre primero ../infraestructura/deploy.sh" >&2 # Decir qué falta
  exit 1                                                 # Detenerse
fi
INSTANCE="$(aws ec2 describe-instances --region "$REGION" --filters "Name=tag:Name,Values=$SERVICE" "Name=instance-state-name,Values=pending,running" --query 'Reservations[0].Instances[0].InstanceId' --output text)" # Buscar la máquina del worker por su etiqueta Name
if [ "$INSTANCE" = "None" ] || [ -z "$INSTANCE" ]; then  # ¿No hay ninguna máquina con ese nombre?
  echo "Error: no hay una máquina con la etiqueta Name=$SERVICE. ¿Está definida en infraestructura/compute.tf y aplicada?" >&2 # Decir qué falta
  exit 1                                                 # Detenerse
fi
echo "    máquina del worker: $INSTANCE"                 # Informar qué máquina se va a actualizar

echo "==> [build] construyendo la imagen"                # Etapa 2: empaquetar el código en una imagen
VERSION="$(date -u +%Y%m%d-%H%M%S)"                      # Versión única: fecha y hora UTC del despliegue
IMAGE="$REGISTRY/$SERVICE:$VERSION"                      # Nombre completo de la imagen en ECR
docker build --platform linux/amd64 --provenance=false --sbom=false -t "$IMAGE" . # Construir para el procesador de las máquinas; sin metadatos extra que ECR mostraría como imágenes sueltas

echo "==> [test] el worker no tiene pruebas automáticas" # Etapa 3: aquí irían sus pruebas si las tuviera

echo "==> [push] subiendo $VERSION a ECR"                # Etapa 4: guardar la imagen en el registro
aws ecr get-login-password --region "$REGION" | docker login --username AWS --password-stdin "$REGISTRY" >/dev/null # Entrar al registro con las credenciales del lab
docker push "$IMAGE"                                     # Subir la imagen con su etiqueta de versión

digest_of() {                                            # Función auxiliar: devuelve el digest (huella) de una etiqueta, o "none" si no existe
  aws ecr describe-images --region "$REGION" --repository-name "$SERVICE" --image-ids imageTag="$1" --query 'imageDetails[0].imageDigest' --output text 2>/dev/null || echo none # Preguntar a ECR por la etiqueta
}
promote() {                                              # Función auxiliar: mueve la etiqueta current a la imagen con el digest dado
  local manifest media                                   # Variables locales de la función
  manifest="$(aws ecr batch-get-image --region "$REGION" --repository-name "$SERVICE" --image-ids imageDigest="$1" --query 'images[0].imageManifest' --output text)" # Leer el manifiesto de la imagen
  media="$(aws ecr batch-get-image --region "$REGION" --repository-name "$SERVICE" --image-ids imageDigest="$1" --query 'images[0].imageManifestMediaType' --output text)" # Leer su tipo de manifiesto
  aws ecr put-image --region "$REGION" --repository-name "$SERVICE" --image-tag current --image-manifest "$manifest" --image-manifest-media-type "$media" >/dev/null # Ponerle la etiqueta current, sin volver a subir nada
}
run_on_worker() {                                        # Función auxiliar: ejecuta un comando en la máquina del worker por SSM y espera el resultado
  local params id status                                 # Variables locales de la función
  params="$(mktemp)"                                     # Archivo temporal con el comando en formato JSON
  printf '{"commands":["%s"]}' "$1" > "$params"          # SSM recibe la lista de comandos como JSON
  id="$(aws ssm send-command --region "$REGION" --instance-ids "$INSTANCE" --document-name AWS-RunShellScript --parameters "file://$params" --query Command.CommandId --output text)" || { rm -f "$params"; return 1; } # Enviar la orden a la máquina; si AWS la rechaza, fallar de inmediato
  rm -f "$params"                                        # El archivo temporal ya no hace falta
  for i in $(seq 1 240); do                              # Revisar hasta 240 veces (40 minutos: la máquina puede estar esperando la imagen)
    sleep 10                                             # Esperar antes de preguntar
    status="$(aws ssm get-command-invocation --region "$REGION" --command-id "$id" --instance-id "$INSTANCE" --query Status --output text 2>/dev/null || echo Pending)" # Estado de la orden (justo al enviarla todavía no existe)
    case "$status" in                                    # Decidir según el estado
      Pending|InProgress|Delayed) continue ;;            # Sigue corriendo: volver a esperar
    esac
    aws ssm get-command-invocation --region "$REGION" --command-id "$id" --instance-id "$INSTANCE" --query StandardOutputContent --output text | tail -5 # Mostrar el final de lo que imprimió la máquina
    [ "$status" = "Success" ]; return                    # Éxito solo si el estado es Success
  done
  return 1                                               # Se agotó el tiempo
}
wait_for_ssm() {                                         # Función auxiliar: espera a que la máquina esté conectada a SSM
  for i in $(seq 1 60); do                               # Intentar hasta 60 veces (10 minutos, por si la máquina acaba de arrancar)
    if [ "$(aws ssm describe-instance-information --region "$REGION" --filters "Key=InstanceIds,Values=$INSTANCE" --query 'InstanceInformationList[0].PingStatus' --output text)" = "Online" ]; then return 0; fi # Conectada: seguir
    echo "    esperando a que la máquina se conecte a SSM (intento $i)" # Mostrar el avance
    sleep 10                                             # Esperar antes del siguiente intento
  done
  return 1                                               # Nunca se conectó
}

echo "==> [promote] moviendo la etiqueta current a $VERSION" # Etapa 5: decirle a la máquina qué versión usar
PREVIOUS="$(digest_of current)"                          # Guardar la versión actual, por si hay que volver atrás
NEW="$(digest_of "$VERSION")"                            # Huella de la imagen recién subida
if [ "$NEW" = "$PREVIOUS" ]; then                        # ¿Es exactamente la misma imagen que ya corre?
  echo "    la imagen no cambió: no hay nada que desplegar" # Informar
  exit 0                                                 # Terminar sin tocar la máquina
fi
promote "$NEW"                                           # Mover current a la imagen nueva
wait_for_ssm || { echo "Error: la máquina $INSTANCE no se conectó a SSM." >&2; exit 1; } # Sin SSM no se le puede dar órdenes

if [ "$PREVIOUS" = "none" ]; then                        # Primer despliegue: el arranque de la máquina ya está esperando la imagen current
  echo "==> [rollout] primer despliegue: la máquina baja la imagen sola" # Etapa 6: no hace falta darle la orden
else
  echo "==> [rollout] pidiendo a la máquina que use la versión nueva (SSM)" # Etapa 6: actualizar el contenedor en la misma máquina
  if ! run_on_worker "/usr/local/bin/update-service.sh"; then # ¿Falló la actualización?
    echo "==> [rollback] la actualización falló: volviendo a la versión anterior" >&2 # Etapa de emergencia
    promote "$PREVIOUS"; run_on_worker "/usr/local/bin/update-service.sh" || true # Devolver current a la versión anterior y actualizar otra vez
    exit 1                                               # El despliegue falló
  fi
fi

echo "==> [verify] revisando el contenedor en la máquina" # Etapa 7: el worker no tiene puerto, así que se revisa por SSM
CHECK="for i in \$(seq 1 120); do docker image inspect -f '{{.RepoDigests}}' \$(docker inspect -f '{{.Image}}' $SERVICE 2>/dev/null) 2>/dev/null | grep -q $NEW && break; sleep 10; done; sleep 30; docker inspect -f 'running={{.State.Running}} reinicios={{.RestartCount}}' $SERVICE; docker inspect -f '{{.State.Running}} {{.RestartCount}}' $SERVICE | grep -q '^true 0\$' && docker image inspect -f '{{.RepoDigests}}' \$(docker inspect -f '{{.Image}}' $SERVICE) | grep -q $NEW && ! docker logs $SERVICE 2>&1 | grep -q Traceback" # Comando remoto: esperar la imagen nueva, dar 30 s, y exigir contenedor vivo, sin reinicios, con la imagen nueva y sin errores
if ! run_on_worker "$CHECK"; then                        # ¿El contenedor no quedó bien?
  if [ "$PREVIOUS" != "none" ]; then                     # Solo se puede volver atrás si había una versión anterior
    echo "==> [rollback] el worker no quedó bien: volviendo a la versión anterior" >&2 # Etapa de emergencia
    promote "$PREVIOUS"; run_on_worker "/usr/local/bin/update-service.sh" || true # Devolver current a la versión anterior y actualizar otra vez
  fi
  echo "Error: el worker no quedó corriendo con $VERSION. Mira /var/log/central-update.log en la máquina." >&2 # Informar el fallo
  exit 1                                                 # El despliegue falló
fi
echo "Listo: $SERVICE $VERSION está en producción en $INSTANCE." # Mensaje de éxito
