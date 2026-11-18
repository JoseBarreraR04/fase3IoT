#!/usr/bin/env bash
# Pipeline de la infraestructura: crea o actualiza en AWS las máquinas, la red y el balanceador. No despliega código.
set -euo pipefail                                        # Detenerse ante el primer error, variable sin definir o tubería fallida
cd "$(dirname "$0")"                                     # Trabajar desde la carpeta infraestructura, sin importar desde dónde se llame
ROOT="$(cd .. && pwd)"                                   # Carpeta del proyecto, donde vive .env.cloud
REGION="us-east-1"                                       # La misma región que el valor por defecto de variables.tf

echo "==> [preflight] revisando herramientas y credenciales" # Etapa 1: comprobar que se puede trabajar
for tool in terraform aws; do                            # Programas que necesita este pipeline
  if ! command -v "$tool" >/dev/null 2>&1; then          # ¿Está instalado?
    echo "Error: falta el programa '$tool'." >&2         # Decir cuál falta
    exit 1                                               # Detenerse antes de hacer nada
  fi
done
if ! aws sts get-caller-identity >/dev/null 2>&1; then   # Preguntar a AWS quiénes somos; falla si las credenciales faltan o caducaron
  echo "Error: las credenciales de AWS faltan o caducaron." >&2 # Explicar el problema
  echo "Inicia el Learner Lab, abre 'AWS Details' y copia las credenciales en ~/.aws/credentials." >&2 # Decir cómo arreglarlo
  exit 1                                                 # Detenerse antes de llamar a Terraform
fi

echo "==> [registry] creando los repositorios de imágenes en ECR" # Etapa 2: dónde guardarán los pipelines sus imágenes
for repo in central-api central-worker central-web; do   # Un repositorio por servicio
  if ! aws ecr describe-repositories --region "$REGION" --repository-names "$repo" >/dev/null 2>&1; then # ¿Ya existe?
    aws ecr create-repository --region "$REGION" --repository-name "$repo" --image-tag-mutability MUTABLE >/dev/null # Crearlo; MUTABLE permite mover la etiqueta current
    echo "    repositorio $repo creado"                  # Informar
  else
    echo "    repositorio $repo ya existe"               # Nada que hacer
  fi
done

echo "==> [plan] calculando qué cambia en AWS"           # Etapa 3: mostrar los cambios antes de hacerlos
terraform init -input=false >/dev/null                   # Descargar el proveedor de AWS (solo la primera vez hace algo)
terraform plan -input=false -var "region=$REGION" -out=tfplan # Guardar el plan para aplicar exactamente eso

echo "==> [apply] aplicando el plan (unos minutos)"      # Etapa 4: hacer los cambios
terraform apply -input=false tfplan                      # Aplicar el plan guardado, sin volver a preguntar
rm -f tfplan                                             # El plan ya se usó

API_URL="$(terraform output -raw central_api_url)"       # Dirección pública del API central
WEB_URL="$(terraform output -raw central_web_url)"       # Dirección pública del dashboard
echo "CENTRAL_API_PUBLIC_URL=$API_URL" > "$ROOT/.env.cloud" # Decirle a las tiendas dónde está la sede central; .env no se toca

echo ""                                                  # Línea en blanco para leer mejor
echo "Infraestructura lista. Las máquinas esperan sus imágenes en ECR." # Mensaje de éxito
echo "  Dashboard: $WEB_URL"                             # Dónde se verá el dashboard
echo "  API:       $API_URL"                             # Dónde entregarán las tiendas
echo "  Siguiente: ../central-api/deploy.sh, ../central-worker/deploy.sh y ../central-web/deploy.sh (ver DEPLOY.md)" # Próximo paso
