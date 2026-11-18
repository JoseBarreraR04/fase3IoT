#!/usr/bin/env bash
# Borra todo lo que crearon los pipelines en AWS, para que el Learner Lab deje de gastar crédito.
set -euo pipefail                                        # Detenerse ante el primer error, variable sin definir o tubería fallida
cd "$(dirname "$0")"                                     # Trabajar desde la carpeta infraestructura, sin importar desde dónde se llame
ROOT="$(cd .. && pwd)"                                   # Carpeta del proyecto, donde vive .env.cloud
REGION="us-east-1"                                       # La misma región que el valor por defecto de variables.tf

for tool in terraform aws; do                            # Programas que necesita este script
  if ! command -v "$tool" >/dev/null 2>&1; then          # ¿Está instalado?
    echo "Error: falta el programa '$tool'." >&2         # Decir cuál falta
    exit 1                                               # Detenerse antes de hacer nada
  fi
done
if ! aws sts get-caller-identity >/dev/null 2>&1; then   # Sin credenciales no se puede borrar nada
  echo "Error: las credenciales de AWS faltan o caducaron; no se borró nada." >&2 # Explicar el problema
  exit 1                                                 # Detenerse
fi

if [ -f terraform.tfstate ]; then                        # Sin estado, Terraform no sabe qué existe
  echo "==> Borrando la infraestructura"                 # Mensaje de avance
  terraform init -input=false >/dev/null                 # Asegurar que el proveedor esté descargado
  terraform destroy -auto-approve -input=false -var "region=$REGION" # Borrar todos los recursos sin preguntar
else
  echo "==> No hay terraform.tfstate: no hay infraestructura que borrar" # Informar
fi

echo "==> Borrando los repositorios de imágenes"         # Mensaje de avance
for repo in central-api central-worker central-web; do   # Los repositorios que creó infraestructura/deploy.sh
  aws ecr delete-repository --region "$REGION" --repository-name "$repo" --force >/dev/null 2>&1 && echo "    $repo borrado" || echo "    $repo no existía" # Borrarlo con sus imágenes; si no existe, seguir
done

rm -f "$ROOT/.env.cloud" tfplan                          # La dirección guardada ya no existe
echo "Sede central borrada. 'make up-local' sigue corriendo todo en este computador." # Mensaje de éxito
