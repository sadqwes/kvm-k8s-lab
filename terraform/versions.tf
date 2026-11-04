terraform {
  required_version = ">= 1.5.0"

  # State хранится в GitLab (http backend с блокировкой). Адрес и токен — в переменных TF_HTTP_*.
  backend "http" {}

  required_providers {
    libvirt = {
      source  = "dmacvicar/libvirt"
      version = "~> 0.8.0"
    }
  }
}

provider "libvirt" {
  uri = var.libvirt_uri
}