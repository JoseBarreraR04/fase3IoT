data "aws_ami" "al2023" {  # Buscar la imagen del sistema operativo en vez de escribir un id fijo
  most_recent = true       # Tomar la más reciente que coincida
  owners      = ["amazon"] # Solo imágenes publicadas por Amazon

  filter {                                # Restringir la búsqueda por nombre de imagen
    name   = "name"                       # Filtrar por el nombre de la imagen
    values = ["al2023-ami-2023.*-x86_64"] # Amazon Linux 2023, procesador Intel/AMD de 64 bits
  }
}

data "aws_caller_identity" "current" {} # Leer el número de la cuenta de AWS, que forma parte de la dirección del registro ECR

locals {                                                                                               # Valores calculados una vez y reutilizados abajo
  registry      = "${data.aws_caller_identity.current.account_id}.dkr.ecr.${var.region}.amazonaws.com" # Dirección del registro ECR de esta cuenta
  common_script = file("${path.module}/templates/common.sh.tftpl")                                     # Primeros pasos comunes a todas las máquinas (no tiene huecos)
  update_script = templatefile("${path.module}/templates/update-service.sh.tftpl", {                   # Script que baja la imagen current y arranca el contenedor
    registry = local.registry                                                                          # Registro de donde se bajan las imágenes
    region   = var.region                                                                              # Región del registro
  })
}

resource "aws_instance" "mysql" {                        # La máquina de la base de datos (una sola, nunca se reemplaza)
  ami                    = data.aws_ami.al2023.id        # Imagen del sistema operativo encontrada arriba
  instance_type          = var.instance_type             # Tamaño de la máquina
  key_name               = var.key_name                  # Llave SSH
  iam_instance_profile   = var.instance_profile          # Rol de la máquina (permite usar SSM)
  vpc_security_group_ids = [aws_security_group.mysql.id] # Firewall de esta máquina

  root_block_device { # Disco de la máquina
    volume_size = 16  # 16 GB: espacio para imágenes Docker y los datos
  }

  user_data = templatefile("${path.module}/templates/mysql.sh.tftpl", { # Script que corre al primer arranque
    common        = local.common_script                                 # Primeros pasos comunes
    schema_sql    = file("${path.module}/../central-db/01-schema.sql")  # Esquema de la base (tablas), copiado de central-db/
    seed_sql      = file("${path.module}/../central-db/02-seed.sql")    # Datos iniciales (tiendas), copiados de central-db/
    root_password = var.mysql_root_password                             # Clave del usuario root de MySQL
    database      = var.mysql_database                                  # Base de datos a crear
    db_user       = var.mysql_user                                      # Usuario de la aplicación a crear
    db_password   = var.mysql_password                                  # Clave del usuario de la aplicación
  })

  lifecycle {                    # Reglas especiales para este recurso
    ignore_changes = [user_data] # Nunca reemplazar la máquina de la base: guarda los datos
  }

  tags = {                 # Etiquetas de la máquina
    Name = "central-mysql" # Nombre que se ve en la consola de AWS
  }
}

resource "aws_instance" "rabbitmq" {                        # La máquina de la cola de mensajes (una sola, nunca se reemplaza)
  ami                    = data.aws_ami.al2023.id           # Imagen del sistema operativo encontrada arriba
  instance_type          = var.instance_type                # Tamaño de la máquina
  key_name               = var.key_name                     # Llave SSH
  iam_instance_profile   = var.instance_profile             # Rol de la máquina (permite usar SSM)
  vpc_security_group_ids = [aws_security_group.rabbitmq.id] # Firewall de esta máquina

  root_block_device { # Disco de la máquina
    volume_size = 16  # 16 GB: espacio para imágenes Docker y mensajes en cola
  }

  user_data = templatefile("${path.module}/templates/rabbitmq.sh.tftpl", { # Script que corre al primer arranque
    common            = local.common_script                                # Primeros pasos comunes
    rabbitmq_user     = var.rabbitmq_user                                  # Usuario a crear
    rabbitmq_password = var.rabbitmq_password                              # Su clave
  })

  lifecycle {                    # Reglas especiales para este recurso
    ignore_changes = [user_data] # Nunca reemplazar la máquina de la cola: guarda los mensajes pendientes
  }

  tags = {                    # Etiquetas de la máquina
    Name = "central-rabbitmq" # Nombre que se ve en la consola de AWS
  }
}

resource "aws_instance" "worker" {                        # La máquina del worker: lee lotes de la cola y los guarda en MySQL
  ami                    = data.aws_ami.al2023.id         # Imagen del sistema operativo encontrada arriba
  instance_type          = var.instance_type              # Tamaño de la máquina
  key_name               = var.key_name                   # Llave SSH
  iam_instance_profile   = var.instance_profile           # Rol de la máquina: permite bajar imágenes de ECR y recibir órdenes de SSM
  vpc_security_group_ids = [aws_security_group.worker.id] # Su propio firewall: MySQL y RabbitMQ solo aceptan este grupo y el del API

  root_block_device { # Disco de la máquina
    volume_size = 16  # 16 GB: espacio para imágenes Docker
  }

  user_data = templatefile("${path.module}/templates/worker.sh.tftpl", { # Script que corre al primer arranque
    common            = local.common_script                              # Primeros pasos comunes (swap, Docker, wait_for)
    update_script     = local.update_script                              # Script que baja la imagen current y arranca el contenedor
    mysql_ip          = aws_instance.mysql.private_ip                    # Dónde está la base de datos (IP privada de su máquina)
    rabbitmq_ip       = aws_instance.rabbitmq.private_ip                 # Dónde está la cola (IP privada de su máquina)
    database          = var.mysql_database                               # Nombre de la base de datos
    db_user           = var.mysql_user                                   # Usuario de la base de datos
    db_password       = var.mysql_password                               # Clave de la base de datos
    rabbitmq_user     = var.rabbitmq_user                                # Usuario de la cola
    rabbitmq_password = var.rabbitmq_password                            # Clave de la cola
    queue             = var.ingestion_queue                              # Nombre de la cola de donde lee los lotes
  })
  user_data_replace_on_change = true # Si cambia la configuración, crear una máquina nueva (el código nuevo llega por SSM, no por aquí)

  tags = {                  # Etiquetas de la máquina
    Name = "central-worker" # Nombre que se ve en la consola y que usa central-worker/deploy.sh para encontrarla
  }
}
