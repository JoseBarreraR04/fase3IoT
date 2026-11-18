#!/usr/bin/env bash
# Pipeline del API central: construye la imagen, la prueba, la sube a ECR, la promueve a "current" y reemplaza las máquinas.
# Es independiente de los demás: imagina que esta carpeta es su propio repositorio con su propio GitHub Actions.
set -euo pipefail                                        # Detenerse ante el primer error, variable sin definir o tubería fallida
cd "$(dirname "$0")"                                     # Trabajar desde la carpeta del servicio, sin importar desde dónde se llame
SERVICE="central-api"                                    # Nombre del servicio, del repositorio ECR y del grupo de autoescalado
REGION="us-east-1"                                       # Región donde vive la infraestructura
ALB_NAME="central-alb"                                   # Nombre del balanceador, para encontrar su dirección

echo "==> [preflight] revisando herramientas, credenciales e infraestructura" # Etapa 1: comprobar que se puede desplegar
for tool in docker aws curl; do                          # Programas que necesita este pipeline
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
if [ "$(aws autoscaling describe-auto-scaling-groups --region "$REGION" --auto-scaling-group-names "$SERVICE" --query 'length(AutoScalingGroups)' --output text)" != "1" ]; then # ¿Existe el grupo de máquinas?
  echo "Error: no existe el grupo de autoescalado $SERVICE. Corre primero ../infraestructura/deploy.sh" >&2 # Decir qué falta
  exit 1                                                 # Detenerse
fi
ALB_DNS="$(aws elbv2 describe-load-balancers --region "$REGION" --names "$ALB_NAME" --query 'LoadBalancers[0].DNSName' --output text)" # Dirección pública del balanceador
URL="http://$ALB_DNS:8000/health"                        # Dirección que se revisa al final para saber si el API responde

echo "==> [build] construyendo la imagen"                # Etapa 2: empaquetar el código en una imagen
VERSION="$(date -u +%Y%m%d-%H%M%S)"                      # Versión única: fecha y hora UTC del despliegue
IMAGE="$REGISTRY/$SERVICE:$VERSION"                      # Nombre completo de la imagen en ECR
docker build --platform linux/amd64 --provenance=false --sbom=false -t "$IMAGE" . # Construir para el procesador de las máquinas; sin metadatos extra que ECR mostraría como imágenes sueltas

echo "==> [test] corriendo las pruebas dentro de la imagen" # Etapa 3: si fallan, nada llega a AWS
docker run --rm "$IMAGE" python -m pytest app -q -p no:cacheprovider # Las mismas pruebas de siempre, dentro de la imagen que se va a desplegar

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
rollout() {                                              # Función auxiliar: termina las máquinas del grupo; el grupo crea otras que bajan current al arrancar
  local ids id                                           # Variables locales de la función
  ids="$(aws autoscaling describe-auto-scaling-groups --region "$REGION" --auto-scaling-group-names "$SERVICE" --query 'AutoScalingGroups[0].Instances[].InstanceId' --output text)" || return 1 # Las máquinas que hay ahora en el grupo
  for id in $ids; do                                     # Una por una
    echo "    terminando la máquina $id"                 # Mostrar el avance
    aws autoscaling terminate-instance-in-auto-scaling-group --region "$REGION" --instance-id "$id" --no-should-decrement-desired-capacity >/dev/null || return 1 # Terminarla sin bajar la capacidad deseada: el grupo crea su reemplazo
  done
  echo "    el grupo está creando máquinas nuevas: el servicio no responde por unos minutos" # Avisar del corte (curso introductorio: sin alta disponibilidad)
  sleep 60                                               # Dar tiempo a que el balanceador saque las máquinas viejas antes de verificar
}
verify() {                                               # Función auxiliar: el API debe responder a través del balanceador
  for i in $(seq 1 60); do                               # Intentar hasta 60 veces (10 minutos: una máquina nueva tarda en arrancar)
    if curl -fsS -m 5 "$URL" >/dev/null 2>&1; then return 0; fi # Respondió: todo bien
    sleep 10                                             # Esperar antes del siguiente intento
  done
  return 1                                               # No respondió a tiempo
}

echo "==> [promote] moviendo la etiqueta current a $VERSION" # Etapa 5: decirle a las máquinas qué versión usar
PREVIOUS="$(digest_of current)"                          # Guardar la versión actual, por si hay que volver atrás
NEW="$(digest_of "$VERSION")"                            # Huella de la imagen recién subida
if [ "$NEW" = "$PREVIOUS" ]; then                        # ¿Es exactamente la misma imagen que ya corre?
  echo "    la imagen no cambió: no hay nada que desplegar" # Informar
  exit 0                                                 # Terminar sin tocar las máquinas
fi
promote "$NEW"                                           # Mover current a la imagen nueva

if [ "$PREVIOUS" = "none" ]; then                        # Primer despliegue: las máquinas ya están esperando la imagen current
  echo "==> [rollout] primer despliegue: las máquinas bajan la imagen solas" # Etapa 6: no hace falta reemplazarlas
else
  echo "==> [rollout] reemplazando las máquinas del grupo $SERVICE" # Etapa 6: terminar las máquinas; las nuevas bajan current al arrancar
  if ! rollout; then                                     # ¿Falló el reemplazo?
    echo "==> [rollback] no se pudieron terminar las máquinas: volviendo a la versión anterior" >&2 # Etapa de emergencia
    promote "$PREVIOUS"; rollout || true                 # Devolver current a la versión anterior y reemplazar otra vez
    exit 1                                               # El despliegue falló
  fi
fi

echo "==> [verify] revisando $URL"                       # Etapa 7: comprobar que el servicio responde
if ! verify; then                                        # ¿No responde?
  if [ "$PREVIOUS" != "none" ]; then                     # Solo se puede volver atrás si había una versión anterior
    echo "==> [rollback] el API no responde: volviendo a la versión anterior" >&2 # Etapa de emergencia
    promote "$PREVIOUS"; rollout || true                 # Devolver current a la versión anterior y reemplazar otra vez
  fi
  echo "Error: el API no respondió en $URL" >&2          # Informar el fallo
  exit 1                                                 # El despliegue falló
fi
echo "Listo: $SERVICE $VERSION está en producción ($URL)." # Mensaje de éxito
