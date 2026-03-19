variable "region" {
  default = "us-east-2"
}

variable "instance_count" {
  description = "Number of scan instances to deploy."
  default = 1
}

# Random pet name for resources
resource "random_pet" "suffix" {
  length    = 2
  separator = "-"
}

locals {
  rs = random_pet.suffix.id
}

output "aws_region" {
  value = var.region
}

resource "tls_private_key" "operator" {
  algorithm = "RSA"
}

module "key_pair" {
  source = "terraform-aws-modules/key-pair/aws"

  key_name   = "operator-${local.rs}"
  public_key = tls_private_key.operator.public_key_openssh
}

# write ssh key to file
resource "local_file" "ssh_key" {
  content         = tls_private_key.operator.private_key_pem
  filename        = "${path.module}/operator-${local.rs}.pem"
  file_permission = "0600"
}
