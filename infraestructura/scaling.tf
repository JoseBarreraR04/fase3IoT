resource "aws_launch_template" "api" {                 # Receta para cada máquina del API que crea el grupo
  name_prefix            = "central-api-"              # Nombre en la consola de AWS, más un final aleatorio
  image_id               = data.aws_ami.al2023.id      # Imagen del sistema operativo encontrada en compute.tf
  instance_type          = var.instance_type           # Tamaño de la máquina
  key_name               = var.key_name                # Llave SSH
  vpc_security_group_ids = [aws_security_group.api.id] # Firewall de estas máquinas

  iam_instance_profile {        # Rol de la máquina: permite bajar imágenes de ECR
    name = var.instance_profile # Perfil que ya existe en el Learner Lab
  }

  block_device_mappings {     # Disco de la máquina
    device_name = "/dev/xvda" # Disco raíz de Amazon Linux
    ebs {                     # Configuración del disco
      volume_size = 16        # 16 GB: espacio para imágenes Docker
    }
  }

  user_data = base64encode(templatefile("${path.module}/templates/api.sh.tftpl", { # Script que corre al primer arranque (las launch templates lo piden en base64)
    common            = local.common_script                                        # Primeros pasos comunes
    update_script     = local.update_script                                        # Script que baja la imagen current y arranca el contenedor
    mysql_ip          = aws_instance.mysql.private_ip                              # Dónde está la base de datos
    rabbitmq_ip       = aws_instance.rabbitmq.private_ip                           # Dónde está la cola
    database          = var.mysql_database                                         # Nombre de la base de datos
    db_user           = var.mysql_user                                             # Usuario de la base de datos
    db_password       = var.mysql_password                                         # Clave de la base de datos
    rabbitmq_user     = var.rabbitmq_user                                          # Usuario de la cola
    rabbitmq_password = var.rabbitmq_password                                      # Clave de la cola
    queue             = var.ingestion_queue                                        # Nombre de la cola
  }))

  tag_specifications {         # Etiquetas para cada máquina creada con esta receta
    resource_type = "instance" # Etiquetar las máquinas
    tags = {                   # Las etiquetas
      Name    = "central-api"  # Nombre que se ve en la consola de AWS
      Project = "d1-chain"     # Permite encontrar todo lo que creó este proyecto
    }
  }
}

resource "aws_launch_template" "web" {                 # Receta para cada máquina del dashboard que crea el grupo
  name_prefix            = "central-web-"              # Nombre en la consola de AWS, más un final aleatorio
  image_id               = data.aws_ami.al2023.id      # Imagen del sistema operativo encontrada en compute.tf
  instance_type          = var.instance_type           # Tamaño de la máquina
  key_name               = var.key_name                # Llave SSH
  vpc_security_group_ids = [aws_security_group.web.id] # Firewall de estas máquinas

  iam_instance_profile {        # Rol de la máquina: permite bajar imágenes de ECR
    name = var.instance_profile # Perfil que ya existe en el Learner Lab
  }

  block_device_mappings {     # Disco de la máquina
    device_name = "/dev/xvda" # Disco raíz de Amazon Linux
    ebs {                     # Configuración del disco
      volume_size = 16        # 16 GB: espacio para imágenes Docker
    }
  }

  user_data = base64encode(templatefile("${path.module}/templates/web.sh.tftpl", { # Script que corre al primer arranque (las launch templates lo piden en base64)
    common        = local.common_script                                            # Primeros pasos comunes
    update_script = local.update_script                                            # Script que baja la imagen current y arranca el contenedor
    api_host      = aws_lb.main.dns_name                                           # El dashboard reenvía /api al balanceador
  }))

  tag_specifications {         # Etiquetas para cada máquina creada con esta receta
    resource_type = "instance" # Etiquetar las máquinas
    tags = {                   # Las etiquetas
      Name    = "central-web"  # Nombre que se ve en la consola de AWS
      Project = "d1-chain"     # Permite encontrar todo lo que creó este proyecto
    }
  }
}

resource "aws_autoscaling_group" "api" {                    # Mantiene las máquinas del API: 1 normalmente, hasta 2 con carga
  name                      = "central-api"                 # Nombre que se ve en la consola de AWS
  min_size                  = 1                             # Nunca menos de una máquina
  desired_capacity          = 1                             # Empezar con una máquina
  max_size                  = var.max_instances             # Nunca más de estas (2)
  vpc_zone_identifier       = data.aws_subnets.default.ids  # Subredes donde se pueden crear máquinas
  target_group_arns         = [aws_lb_target_group.api.arn] # Registrar cada máquina en el grupo de destino del API
  health_check_type         = "ELB"                         # Reemplazar las máquinas que el balanceador vea enfermas
  health_check_grace_period = 300                           # Segundos para instalar Docker y bajar la imagen antes de evaluar la salud (5 min)

  launch_template {                                  # Qué receta usar
    id      = aws_launch_template.api.id             # La receta del API
    version = aws_launch_template.api.latest_version # Siempre su versión más nueva
  }


  tag {                              # Etiqueta del grupo mismo
    key                 = "Project"  # Nombre de la etiqueta
    value               = "d1-chain" # Valor de la etiqueta
    propagate_at_launch = false      # Las máquinas reciben sus etiquetas de la launch template
  }

  lifecycle {                           # Reglas especiales para este recurso
    ignore_changes = [desired_capacity] # No deshacer un escalado al volver a aplicar
  }
}

resource "aws_autoscaling_group" "web" {                    # Mantiene las máquinas del dashboard: 1 normalmente, hasta 2 con carga
  name                      = "central-web"                 # Nombre que se ve en la consola de AWS
  min_size                  = 1                             # Nunca menos de una máquina
  desired_capacity          = 1                             # Empezar con una máquina
  max_size                  = var.max_instances             # Nunca más de estas (2)
  vpc_zone_identifier       = data.aws_subnets.default.ids  # Subredes donde se pueden crear máquinas
  target_group_arns         = [aws_lb_target_group.web.arn] # Registrar cada máquina en el grupo de destino del dashboard
  health_check_type         = "ELB"                         # Reemplazar las máquinas que el balanceador vea enfermas
  health_check_grace_period = 300                           # Segundos para instalar Docker y bajar la imagen antes de evaluar la salud (5 min)

  launch_template {                                  # Qué receta usar
    id      = aws_launch_template.web.id             # La receta del dashboard
    version = aws_launch_template.web.latest_version # Siempre su versión más nueva
  }


  tag {                              # Etiqueta del grupo mismo
    key                 = "Project"  # Nombre de la etiqueta
    value               = "d1-chain" # Valor de la etiqueta
    propagate_at_launch = false      # Las máquinas reciben sus etiquetas de la launch template
  }

  lifecycle {                           # Reglas especiales para este recurso
    ignore_changes = [desired_capacity] # No deshacer un escalado al volver a aplicar
  }
}

resource "aws_autoscaling_policy" "api_cpu" {             # Agrega o quita máquinas del API para mantener la CPU cerca de una meta
  name                   = "central-api-cpu"              # Nombre que se ve en la consola de AWS
  autoscaling_group_name = aws_autoscaling_group.api.name # El grupo que controla esta regla
  policy_type            = "TargetTrackingScaling"        # Mantener una métrica cerca de un valor; AWS hace las cuentas

  target_tracking_configuration {                         # La métrica y su meta
    predefined_metric_specification {                     # Usar una métrica que AWS ya ofrece
      predefined_metric_type = "ASGAverageCPUUtilization" # CPU promedio de las máquinas del grupo
    }
    target_value = 60 # Agregar una máquina por encima de 60 % de CPU, quitarla bien por debajo
  }
}

resource "aws_autoscaling_policy" "web_cpu" {             # Agrega o quita máquinas del dashboard para mantener la CPU cerca de una meta
  name                   = "central-web-cpu"              # Nombre que se ve en la consola de AWS
  autoscaling_group_name = aws_autoscaling_group.web.name # El grupo que controla esta regla
  policy_type            = "TargetTrackingScaling"        # Mantener una métrica cerca de un valor; AWS hace las cuentas

  target_tracking_configuration {                         # La métrica y su meta
    predefined_metric_specification {                     # Usar una métrica que AWS ya ofrece
      predefined_metric_type = "ASGAverageCPUUtilization" # CPU promedio de las máquinas del grupo
    }
    target_value = 60 # Agregar una máquina por encima de 60 % de CPU, quitarla bien por debajo
  }
}
