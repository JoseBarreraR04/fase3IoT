# Imagen de herramientas para la fase 3 (contenedor aws_dev_environment).
# Construir y usar: ver GUIA-PASO-A-PASO.md, paso B2.
# Trae todo lo que piden los pipelines y que Windows no tiene:
#   make, bash, AWS CLI v2, Terraform, Docker CLI (+ buildx y compose), curl, jq, ssh, nano.
# El Docker que usa es el de Docker Desktop (se monta su socket), así que los
# contenedores e imágenes que crea aparecen en Docker Desktop como siempre.
FROM debian:bookworm-slim

ARG TERRAFORM_VERSION=1.9.8

# Utilidades básicas
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      bash make curl unzip jq ca-certificates gnupg openssh-client nano less git netcat-openbsd \
 && rm -rf /var/lib/apt/lists/*

# Docker CLI + buildx + compose (solo el cliente; el motor es el de Docker Desktop)
RUN install -m 0755 -d /etc/apt/keyrings \
 && curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc \
 && chmod a+r /etc/apt/keyrings/docker.asc \
 && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian bookworm stable" \
      > /etc/apt/sources.list.d/docker.list \
 && apt-get update \
 && apt-get install -y --no-install-recommends docker-ce-cli docker-buildx-plugin docker-compose-plugin \
 && rm -rf /var/lib/apt/lists/*

# AWS CLI v2 y Terraform (descargas oficiales)
RUN set -eux; \
    case "$(uname -m)" in \
      x86_64)  AWS_ARCH=x86_64;  TF_ARCH=amd64 ;; \
      aarch64) AWS_ARCH=aarch64; TF_ARCH=arm64 ;; \
      *) echo "Arquitectura no soportada: $(uname -m)"; exit 1 ;; \
    esac; \
    cd /tmp; \
    curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-${AWS_ARCH}.zip" -o awscli.zip; \
    unzip -q awscli.zip; ./aws/install; \
    curl -fsSL "https://releases.hashicorp.com/terraform/${TERRAFORM_VERSION}/terraform_${TERRAFORM_VERSION}_linux_${TF_ARCH}.zip" -o tf.zip; \
    unzip -q tf.zip -d /usr/local/bin; \
    rm -rf /tmp/*; \
    aws --version; terraform version; docker --version; docker compose version

ENV AWS_DEFAULT_REGION=us-east-1 \
    AWS_REGION=us-east-1

# Carpeta privada para la llave SSH (chmod no funciona en carpetas de Windows)
RUN mkdir -p /root/.ssh && chmod 700 /root/.ssh

WORKDIR /app
CMD ["sleep", "infinity"]
