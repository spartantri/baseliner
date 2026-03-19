variable "vpc_cidr" {
  default = "10.100.0.0/16"
}

# Create vpc
resource "aws_vpc" "operator" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true
  instance_tenancy     = "default"

  tags = {
    Name = "operator_vpc"
  }
}

data "aws_availability_zones" "available" {}

# Create Internet Gateway
resource "aws_internet_gateway" "operator-igw" {
  vpc_id = aws_vpc.operator.id

  tags = {
    Name = "operator_Internet_Gateway"
  }
}

resource "aws_main_route_table_association" "operator" {
  vpc_id         = aws_vpc.operator.id
  route_table_id = aws_route_table.operator-rt.id
}

# Route Table
resource "aws_route_table" "operator-rt" {
  vpc_id = aws_vpc.operator.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.operator-igw.id
  }

  tags = {
    Name = "OperatorLab_Routing_Table"
  }
}

output "vpc_id" {
  value = aws_vpc.operator.id
}

output "vpc_prefix" {
  value = aws_vpc.operator.cidr_block
}

variable "scan_subnet_name" {
  default = "scan_subnet"
}

variable "scan_subnet_prefix" {
  default = "10.100.10.0/24"
}

# Create the scan_subnet subnet
resource "aws_subnet" "scan_subnet" {

  vpc_id  = aws_vpc.operator.id
  cidr_block              = var.scan_subnet_prefix
  availability_zone       = data.aws_availability_zones.available.names[1]
  map_public_ip_on_launch = true

  tags = {
    Name = var.scan_subnet_name
  }
  depends_on = [aws_vpc.operator]
}

output "scan_subnet_id" {
  value = aws_subnet.scan_subnet.id
}

output "scan_subnet_prefix" {
  value = aws_subnet.scan_subnet.cidr_block
}
