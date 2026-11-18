terraform {                     # Configuración general de Terraform
  required_version = ">= 1.5"   # Versión mínima de la herramienta terraform con la que funciona este código
  required_providers {          # Plugins que Terraform debe descargar
    aws = {                     # El plugin que habla con AWS
      source  = "hashicorp/aws" # De dónde se descarga (el registro público de Terraform)
      version = "~> 6.0"        # Cualquier versión 6.x, nunca una versión mayor nueva
    }
  }
}

provider "aws" {           # Cómo se conecta Terraform a AWS
  region = var.region      # Región donde se crea todo
  default_tags {           # Etiquetas que se agregan solas a todo recurso que las acepte
    tags = {               # El mapa de etiquetas
      Project = "d1-chain" # Permite encontrar (y borrar) todo lo que creó este proyecto
    }
  }
}
