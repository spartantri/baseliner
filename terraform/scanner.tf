locals {
  user_data_rendered = templatefile("${path.module}/files/linux/scan-ec2.sh.tpl", {
    region                     = var.region
    linux_os                   = "ubuntu"
    baseliner_frontend_service = file("${path.module}/files/linux/baseliner-frontend.service")
    baseliner_backend_service  = file("${path.module}/files/linux/baseliner-backend.service")
  })
}

# The terraform file that creates a Linux instance for scanning
variable "instance_type_ubuntu" {
  description = "The AWS instance type to use for servers."
  #default     = "t3.micro"
  default     = "t3a.medium"
}

variable "root_block_device_size_ubuntu" {
  description = "The volume size of the root block device."
  default     =  60
}

data "aws_ami" "ubuntu" {
  most_recent      = true
  owners           = ["099720109477"] # Canonical

  filter {
    name   = "name"
    # values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"]
  }

  filter {
    name   = "root-device-type"
    values = ["ebs"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }

  filter {
    name   = "architecture"
    values = ["x86_64"]
  }
}

resource "aws_instance" "ubuntu" {
  count                  = var.instance_count
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.instance_type_ubuntu
  subnet_id              = aws_subnet.scan_subnet.id
  key_name               = module.key_pair.key_pair_name
  vpc_security_group_ids = [aws_security_group.linux_ingress.id, aws_security_group.linux_ssh_ingress.id, aws_security_group.linux_allow_all_internal.id]

  connection {
    type        = "ssh"
    user        = "ubuntu"
    private_key = tls_private_key.private_key.private_key_pem
    host        = self.public_ip
  }

  tags = {
    "Name" = "scan-ec2"
  }

  root_block_device {
    volume_type           = "gp3"
    volume_size           = var.root_block_device_size_ubuntu
    delete_on_termination = "true"
  }

  user_data = local.user_data_rendered

}

resource "local_file" "ubuntu" {
  # For inspecting the rendered bash script as it is loaded onto linux system
  content = local.user_data_rendered
  filename = "${path.module}/output/linux/scan.sh"
}

resource "null_resource" "ubuntu_healthcheck" {
  count = var.wait_for_completion == 1 ? var.instance_count : 0
  depends_on = [aws_instance.ubuntu]

  connection {
    type        = "ssh"
    user        = "ubuntu"
    private_key = tls_private_key.operator.private_key_pem
    host        = aws_instance.ubuntu[count.index].public_ip
  }

  provisioner "remote-exec" {
    inline = [
      "echo 'Waiting for bootstrap to complete...'",
      "while [ ! -f /home/ubuntu/bootstrap.done ]; do sleep 5; done",
      "echo 'Bootstrap completed on instance ${count.index + 1}'"
    ]
  }
}



output "details_scan_ec2" {
  value = <<SCANNER
----------------
scan-ec2
----------------
%{ for i, instance in aws_instance.ubuntu ~}

Instance     ${i + 1}
Public IP:   ${instance.public_ip}
Private IP:  ${instance.private_ip}
Instance ID: ${instance.id}
SSH command: ssh -i operator-${local.rs}.pem -L 7170:127.0.0.1:7170 -L 7171:127.0.0.1:7171  -L 8501:127.0.0.1:8501 ubuntu@${instance.public_ip}
%{ endfor ~}
SCANNER
}

