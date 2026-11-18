#!/usr/bin/env bash
# Falla si alguna línea de código de infraestructura/ o de los pipelines de servicio no tiene comentario (regla de la clase).
set -euo pipefail                                        # Detenerse ante el primer error
cd "$(dirname "$0")"                                     # Trabajar desde la carpeta infraestructura
bad=$(awk '  # Inicio del programa que revisa los archivos
  /^[[:space:]]*$/ { next }                              # Saltar líneas vacías
  /^#!/ { next }                                         # Saltar la línea shebang, no admite comentario
  /^[[:space:]]*[})\]]*[[:space:]]*$/ { next }           # Saltar líneas que solo cierran un bloque
  /^[[:space:]]*(fi|done|esac|else)[[:space:]]*$/ { next } # Saltar líneas que solo cierran un bloque de bash
  /^[A-Z_]+$/ { next }                                   # Saltar el final de un heredoc (SQL, SCRIPT): no admite comentario
  /#/ { next }                                           # Las líneas con comentario están bien
  { printf "%s:%d: %s\n", FILENAME, FNR, $0 }            # Cualquier otra línea no tiene comentario
' *.tf *.sh templates/*.tftpl $(ls ../central-*/deploy.sh 2>/dev/null)) # Revisar Terraform, scripts, plantillas y pipelines de servicio
if [ -n "$bad" ]; then                                   # ¿Se encontraron líneas sin comentario?
  echo "Líneas sin comentario:"; echo "$bad"             # Mostrarlas
  exit 1                                                 # Informar el fallo
fi
echo "OK: todas las líneas de código tienen comentario"  # Todo bien
