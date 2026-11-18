output "central_api_url" {                            # Dirección a la que las tiendas envían sus ventas
  description = "URL del API central"                 # Texto de ayuda que muestra Terraform
  value       = "http://${aws_lb.main.dns_name}:8000" # Dirección del balanceador más el puerto del API
}

output "central_web_url" {                       # Dirección del dashboard
  description = "URL del dashboard"              # Texto de ayuda que muestra Terraform
  value       = "http://${aws_lb.main.dns_name}" # Dirección del balanceador, puerto HTTP por defecto
}

output "ecr_registry" {                     # Registro ECR donde los pipelines suben las imágenes
  description = "Registro ECR de la cuenta" # Texto de ayuda que muestra Terraform
  value       = local.registry              # Calculado en compute.tf
}

output "ssh_addresses" {                                                                                 # Dónde abrir una sesión SSH en cada máquina
  description = "IP publica de las maquinas fijas (las del API y el dashboard cambian: usar la AWS CLI)" # Texto de ayuda que muestra Terraform
  value = {                                                                                              # Un mapa de servicio a dirección
    mysql    = aws_instance.mysql.public_ip                                                              # Máquina de la base de datos
    rabbitmq = aws_instance.rabbitmq.public_ip                                                           # Máquina de la cola
    worker   = aws_instance.worker.public_ip                                                             # Máquina del worker
  }
}
