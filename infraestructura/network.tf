data "aws_vpc" "default" { # Busca la VPC por defecto que ya trae toda cuenta
  default = true           # Elige la que está marcada como "por defecto"
}

data "aws_ec2_instance_type_offerings" "available" { # Pregunta a AWS qué zonas ofrecen nuestro tamaño de máquina
  location_type = "availability-zone"                # La respuesta viene por zona
  filter {                                           # Acota la búsqueda
    name   = "instance-type"                         # Filtra por tamaño de máquina
    values = [var.instance_type]                     # Solo el tamaño que vamos a usar
  }
}

data "aws_subnets" "default" {         # Subredes de la VPC por defecto en zonas que ofrecen nuestro tamaño
  filter {                             # Acota la búsqueda
    name   = "vpc-id"                  # Filtra por la VPC a la que pertenecen
    values = [data.aws_vpc.default.id] # Solo la VPC por defecto
  }
  filter {                                                            # Acota la búsqueda otra vez
    name   = "availability-zone"                                      # Filtra por zona
    values = data.aws_ec2_instance_type_offerings.available.locations # Evita zonas como us-east-1e, que no tienen t3.micro
  }
}

resource "aws_security_group" "alb" {                                  # Firewall del balanceador: la única puerta pública
  name        = "central-alb"                                          # Nombre que se ve en la consola de AWS
  description = "Balanceador: puertos 80 y 8000 desde cualquier lugar" # Propósito que se ve en la consola (sin tildes: AWS no las acepta aquí)
  vpc_id      = data.aws_vpc.default.id                                # Se crea dentro de la VPC por defecto

  ingress {                     # Regla: Dashboard: permitir que los navegadores lleguen al dashboard
    description = "Dashboard"   # Para qué es esta regla
    from_port   = 80            # Primer puerto del rango permitido
    to_port     = 80            # Último puerto del rango permitido
    protocol    = "tcp"         # Tráfico TCP
    cidr_blocks = ["0.0.0.0/0"] # Desde cualquier lugar de internet
  }

  ingress {                     # Regla: API central: permitir que las tiendas lleguen al API
    description = "API central" # Para qué es esta regla
    from_port   = 8000          # Primer puerto del rango permitido
    to_port     = 8000          # Último puerto del rango permitido
    protocol    = "tcp"         # Tráfico TCP
    cidr_blocks = ["0.0.0.0/0"] # Desde cualquier lugar: no conocemos las IPs públicas de las tiendas
  }

  egress {                      # Regla: permitir todo el tráfico de salida (hacia las máquinas que tiene detrás)
    from_port   = 0             # Todos los puertos
    to_port     = 0             # Todos los puertos
    protocol    = "-1"          # Todos los protocolos
    cidr_blocks = ["0.0.0.0/0"] # Hacia cualquier destino
  }
}
resource "aws_security_group" "web" {                       # Firewall de las máquinas del dashboard
  name        = "central-web"                               # Nombre que se ve en la consola de AWS
  description = "Dashboard: HTTP solo desde el balanceador" # Propósito que se ve en la consola (sin tildes: AWS no las acepta aquí)
  vpc_id      = data.aws_vpc.default.id                     # Se crea dentro de la VPC por defecto

  ingress {                                       # Regla: HTTP desde el balanceador: solo el balanceador puede hablar con el dashboard
    description     = "HTTP desde el balanceador" # Para qué es esta regla
    from_port       = 80                          # Primer puerto del rango permitido
    to_port         = 80                          # Último puerto del rango permitido
    protocol        = "tcp"                       # Tráfico TCP
    security_groups = [aws_security_group.alb.id] # Solo el balanceador, no internet
  }

  ingress {                      # Regla: SSH, para entrar a la máquina por consola
    description = "SSH"          # Para qué es esta regla
    from_port   = 22             # Primer puerto del rango permitido
    to_port     = 22             # Último puerto del rango permitido
    protocol    = "tcp"          # Tráfico TCP
    cidr_blocks = [var.ssh_cidr] # Solo desde el rango elegido en las variables
  }

  egress {                      # Regla: permitir todo el tráfico de salida (descargar Docker e imágenes de ECR)
    from_port   = 0             # Todos los puertos
    to_port     = 0             # Todos los puertos
    protocol    = "-1"          # Todos los protocolos
    cidr_blocks = ["0.0.0.0/0"] # Hacia cualquier destino
  }
}
resource "aws_security_group" "api" {                        # Firewall de las máquinas del API
  name        = "central-api"                                # Nombre que se ve en la consola de AWS
  description = "API: puerto 8000 solo desde el balanceador" # Propósito que se ve en la consola (sin tildes: AWS no las acepta aquí)
  vpc_id      = data.aws_vpc.default.id                      # Se crea dentro de la VPC por defecto

  ingress {                                       # Regla: API desde el balanceador: solo el balanceador puede hablar con el API
    description     = "API desde el balanceador"  # Para qué es esta regla
    from_port       = 8000                        # Primer puerto del rango permitido
    to_port         = 8000                        # Último puerto del rango permitido
    protocol        = "tcp"                       # Tráfico TCP
    security_groups = [aws_security_group.alb.id] # Solo el balanceador, no internet
  }

  ingress {                      # Regla: SSH, para entrar a la máquina por consola
    description = "SSH"          # Para qué es esta regla
    from_port   = 22             # Primer puerto del rango permitido
    to_port     = 22             # Último puerto del rango permitido
    protocol    = "tcp"          # Tráfico TCP
    cidr_blocks = [var.ssh_cidr] # Solo desde el rango elegido en las variables
  }

  egress {                      # Regla: permitir todo el tráfico de salida (descargar imágenes y conectarse a MySQL y RabbitMQ)
    from_port   = 0             # Todos los puertos
    to_port     = 0             # Todos los puertos
    protocol    = "-1"          # Todos los protocolos
    cidr_blocks = ["0.0.0.0/0"] # Hacia cualquier destino
  }
}
resource "aws_security_group" "worker" {         # Firewall de la máquina del worker
  name        = "central-worker"                 # Nombre que se ve en la consola de AWS
  description = "Worker: nada entra excepto SSH" # Propósito que se ve en la consola (sin tildes: AWS no las acepta aquí)
  vpc_id      = data.aws_vpc.default.id          # Se crea dentro de la VPC por defecto

  ingress {                      # Regla: SSH, para entrar a la máquina por consola
    description = "SSH"          # Para qué es esta regla
    from_port   = 22             # Primer puerto del rango permitido
    to_port     = 22             # Último puerto del rango permitido
    protocol    = "tcp"          # Tráfico TCP
    cidr_blocks = [var.ssh_cidr] # Solo desde el rango elegido en las variables
  }

  egress {                      # Regla: permitir todo el tráfico de salida (se conecta a RabbitMQ y a MySQL, y a SSM para recibir despliegues)
    from_port   = 0             # Todos los puertos
    to_port     = 0             # Todos los puertos
    protocol    = "-1"          # Todos los protocolos
    cidr_blocks = ["0.0.0.0/0"] # Hacia cualquier destino
  }
}
resource "aws_security_group" "rabbitmq" {                     # Firewall de la máquina de la cola de mensajes
  name        = "central-rabbitmq"                             # Nombre que se ve en la consola de AWS
  description = "RabbitMQ: AMQP solo desde el API y el worker" # Propósito que se ve en la consola (sin tildes: AWS no las acepta aquí)
  vpc_id      = data.aws_vpc.default.id                        # Se crea dentro de la VPC por defecto

  ingress {                                                                     # Regla: AMQP: permitir que el API y el worker usen la cola
    description     = "AMQP"                                                    # Para qué es esta regla
    from_port       = 5672                                                      # Primer puerto del rango permitido
    to_port         = 5672                                                      # Último puerto del rango permitido
    protocol        = "tcp"                                                     # Tráfico TCP
    security_groups = [aws_security_group.api.id, aws_security_group.worker.id] # Solo máquinas que usan estos dos firewalls
  }

  ingress {                      # Regla: SSH, para entrar a la máquina por consola
    description = "SSH"          # Para qué es esta regla
    from_port   = 22             # Primer puerto del rango permitido
    to_port     = 22             # Último puerto del rango permitido
    protocol    = "tcp"          # Tráfico TCP
    cidr_blocks = [var.ssh_cidr] # Solo desde el rango elegido en las variables
  }

  egress {                      # Regla: permitir todo el tráfico de salida (descargar Docker e imágenes)
    from_port   = 0             # Todos los puertos
    to_port     = 0             # Todos los puertos
    protocol    = "-1"          # Todos los protocolos
    cidr_blocks = ["0.0.0.0/0"] # Hacia cualquier destino
  }
}
resource "aws_security_group" "mysql" {                     # Firewall de la máquina de la base de datos
  name        = "central-mysql"                             # Nombre que se ve en la consola de AWS
  description = "MySQL: 3306 solo desde el API y el worker" # Propósito que se ve en la consola (sin tildes: AWS no las acepta aquí)
  vpc_id      = data.aws_vpc.default.id                     # Se crea dentro de la VPC por defecto

  ingress {                                                                     # Regla: MySQL: permitir que el API y el worker consulten la base de datos
    description     = "MySQL"                                                   # Para qué es esta regla
    from_port       = 3306                                                      # Primer puerto del rango permitido
    to_port         = 3306                                                      # Último puerto del rango permitido
    protocol        = "tcp"                                                     # Tráfico TCP
    security_groups = [aws_security_group.api.id, aws_security_group.worker.id] # Solo máquinas que usan estos dos firewalls
  }

  ingress {                      # Regla: SSH, para entrar a la máquina por consola
    description = "SSH"          # Para qué es esta regla
    from_port   = 22             # Primer puerto del rango permitido
    to_port     = 22             # Último puerto del rango permitido
    protocol    = "tcp"          # Tráfico TCP
    cidr_blocks = [var.ssh_cidr] # Solo desde el rango elegido en las variables
  }

  egress {                      # Regla: permitir todo el tráfico de salida (descargar Docker e imágenes)
    from_port   = 0             # Todos los puertos
    to_port     = 0             # Todos los puertos
    protocol    = "-1"          # Todos los protocolos
    cidr_blocks = ["0.0.0.0/0"] # Hacia cualquier destino
  }
}
