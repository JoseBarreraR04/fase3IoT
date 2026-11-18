resource "aws_lb" "main" {                          # El balanceador: una sola puerta pública para el API y el dashboard
  name               = "central-alb"                # Nombre que se ve en la consola de AWS
  load_balancer_type = "application"                # Balanceador de capa 7: entiende HTTP
  security_groups    = [aws_security_group.alb.id]  # Firewall que deja entrar los puertos 80 y 8000
  subnets            = data.aws_subnets.default.ids # Repartido en las subredes por defecto (al menos dos zonas)
}

resource "aws_lb_target_group" "api" {           # El grupo de máquinas del API
  name                 = "central-api"           # Nombre que se ve en la consola de AWS
  port                 = 8000                    # Puerto en el que escuchan las máquinas del API
  protocol             = "HTTP"                  # HTTP simple entre el balanceador y las máquinas
  vpc_id               = data.aws_vpc.default.id # VPC donde viven las máquinas
  deregistration_delay = 30                      # Segundos para terminar peticiones antes de sacar una máquina

  health_check {                    # Cómo decide el balanceador que una máquina está sana
    path                = "/health" # El endpoint de salud del API
    healthy_threshold   = 2         # Aciertos seguidos para considerarla sana
    unhealthy_threshold = 3         # Fallos seguidos para considerarla enferma
    interval            = 15        # Segundos entre revisiones
  }
}

resource "aws_lb_target_group" "web" {           # El grupo de máquinas del dashboard
  name                 = "central-web"           # Nombre que se ve en la consola de AWS
  port                 = 80                      # Puerto en el que escuchan las máquinas del dashboard
  protocol             = "HTTP"                  # HTTP simple entre el balanceador y las máquinas
  vpc_id               = data.aws_vpc.default.id # VPC donde viven las máquinas
  deregistration_delay = 30                      # Segundos para terminar peticiones antes de sacar una máquina

  health_check {              # Cómo decide el balanceador que una máquina está sana
    path                = "/" # La página de inicio del dashboard
    healthy_threshold   = 2   # Aciertos seguidos para considerarla sana
    unhealthy_threshold = 3   # Fallos seguidos para considerarla enferma
    interval            = 15  # Segundos entre revisiones
  }
}

resource "aws_lb_listener" "web" {    # Escucha en el puerto 80 para los navegadores
  load_balancer_arn = aws_lb.main.arn # Lo conecta al balanceador
  port              = 80              # Puerto en el que escucha
  protocol          = "HTTP"          # HTTP simple

  default_action {                                 # Qué hacer con cada petición
    type             = "forward"                   # Pasarla a un grupo de máquinas
    target_group_arn = aws_lb_target_group.web.arn # El grupo del dashboard
  }
}

resource "aws_lb_listener" "api" {    # Escucha en el puerto 8000 para las tiendas
  load_balancer_arn = aws_lb.main.arn # Lo conecta al balanceador
  port              = 8000            # Puerto en el que escucha
  protocol          = "HTTP"          # HTTP simple

  default_action {                                 # Qué hacer con cada petición
    type             = "forward"                   # Pasarla a un grupo de máquinas
    target_group_arn = aws_lb_target_group.api.arn # El grupo del API
  }
}
