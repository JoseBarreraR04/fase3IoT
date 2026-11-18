variable "region" {                                                # Entrada: la región de AWS
  description = "Region de AWS (el Learner Lab permite us-east-1)" # Texto de ayuda que muestra Terraform
  type        = string                                             # El valor es un texto
  default     = "us-east-1"                                        # Región que se usa si no eliges otra
}

variable "instance_type" {                                      # Entrada: el tamaño de todas las máquinas EC2
  description = "Tipo de instancia EC2 para todas las maquinas" # Texto de ayuda que muestra Terraform
  type        = string                                          # El valor es un texto
  default     = "t3.micro"                                      # 2 vCPU y 1 GB de RAM: el tamaño práctico más pequeño
}

variable "max_instances" {                                           # Entrada: cuántas máquinas puede tener como máximo cada grupo
  description = "Maximo de maquinas para el API y para el dashboard" # Texto de ayuda que muestra Terraform
  type        = number                                               # El valor es un número
  default     = 2                                                    # Dos es el límite pedido en clase
}

variable "key_name" {                                                      # Entrada: el par de llaves SSH que reciben las máquinas
  description = "Par de llaves EC2 existente (el Learner Lab trae vockey)" # Texto de ayuda que muestra Terraform
  type        = string                                                     # El valor es un texto
  default     = "vockey"                                                   # El par de llaves que ya tiene toda cuenta del Learner Lab
}

variable "instance_profile" {                                                            # Entrada: el perfil IAM que da permisos a las máquinas
  description = "Perfil de instancia existente (el Learner Lab trae LabInstanceProfile)" # Texto de ayuda que muestra Terraform
  type        = string                                                                   # El valor es un texto
  default     = "LabInstanceProfile"                                                     # Permite bajar imágenes de ECR y recibir órdenes de SSM
}

variable "ssh_cidr" {                                   # Entrada: desde dónde se permite entrar por SSH
  description = "Rango de IPs que puede entrar por SSH" # Texto de ayuda que muestra Terraform
  type        = string                                  # El valor es un texto
  default     = "0.0.0.0/0"                             # Desde cualquier lugar; sirve para clase, en la vida real se restringe
}

variable "mysql_root_password" {         # Entrada: clave del administrador de MySQL
  description = "Clave de root de MySQL" # Texto de ayuda que muestra Terraform
  type        = string                   # El valor es un texto
  sensitive   = true                     # Terraform no la muestra en pantalla
  default     = "central_root_password"  # Igual que en modo local; solo para clase
}

variable "mysql_database" {                        # Entrada: nombre de la base de datos central
  description = "Nombre de la base de datos MySQL" # Texto de ayuda que muestra Terraform
  type        = string                             # El valor es un texto
  default     = "central"                          # Igual que en modo local
}

variable "mysql_user" {                          # Entrada: usuario de la aplicación en MySQL
  description = "Usuario de aplicacion de MySQL" # Texto de ayuda que muestra Terraform
  type        = string                           # El valor es un texto
  default     = "central"                        # Igual que en modo local
}

variable "mysql_password" {                                # Entrada: clave del usuario de la aplicación
  description = "Clave del usuario de aplicacion de MySQL" # Texto de ayuda que muestra Terraform
  type        = string                                     # El valor es un texto
  sensitive   = true                                       # Terraform no la muestra en pantalla
  default     = "central_password"                         # Igual que en modo local; solo para clase
}

variable "rabbitmq_user" {            # Entrada: usuario de RabbitMQ
  description = "Usuario de RabbitMQ" # Texto de ayuda que muestra Terraform
  type        = string                # El valor es un texto
  default     = "central"             # Igual que en modo local
}

variable "rabbitmq_password" {      # Entrada: clave de RabbitMQ
  description = "Clave de RabbitMQ" # Texto de ayuda que muestra Terraform
  type        = string              # El valor es un texto
  sensitive   = true                # Terraform no la muestra en pantalla
  default     = "central_password"  # Igual que en modo local; solo para clase
}

variable "ingestion_queue" {                                       # Entrada: nombre de la cola entre el API y el worker
  description = "Cola de RabbitMQ que lleva los lotes de facturas" # Texto de ayuda que muestra Terraform
  type        = string                                             # El valor es un texto
  default     = "invoice-batches"                                  # Igual que en modo local
}
