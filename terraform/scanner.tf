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

  user_data = data.template_file.ubuntu.rendered

}

data "template_file" "ubuntu" {
  template = file("${path.module}/files/linux/scan-ec2.sh.tpl")

  vars = {
    region    = var.region
    linux_os  = "ubuntu"
  }
}

resource "local_file" "ubuntu" {
  # For inspecting the rendered bash script as it is loaded onto linux system
  content = data.template_file.ubuntu.rendered
  filename = "${path.module}/output/linux/scan.sh"
}

resource "null_resource" "ubuntu_healthcheck" {
  count = var.instance_count
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
SSH command: ssh -i operator-${local.rs}.pem ubuntu@${instance.public_ip}
%{ endfor ~}
SCANNER
}

