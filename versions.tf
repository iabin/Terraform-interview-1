terraform {
  required_version = ">= 1.3.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
      # The module writes to three provider configurations: default (prod,
      # primary region), dr (prod, DR region) and central (backup account).
      configuration_aliases = [aws.dr, aws.central]
    }
  }
}
