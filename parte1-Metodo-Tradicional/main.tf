terraform {
  required_version = ">= 1.11"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.0" }
  }
  backend "s3" {
    bucket       = "tfstate-923788823291-us-east-2"
    key          = "parte1-tradicional/terraform.tfstate"
    region       = "us-east-2"
    use_lockfile = true
  }
}

provider "aws" {
  region = "us-east-2"
}

locals {
  subnets = {
    ventas         = { cidr = "192.168.0.0/23",   host_ip = "192.168.0.10" }
    produccion     = { cidr = "192.168.2.0/24",   host_ip = "192.168.2.10" }
    ingenieria     = { cidr = "192.168.3.0/25",   host_ip = "192.168.3.10" }
    administracion = { cidr = "192.168.3.128/26", host_ip = "192.168.3.138" }
    rrhh           = { cidr = "192.168.3.192/27", host_ip = null }
    wan            = { cidr = "192.168.3.224/28", host_ip = null }
  }
}

data "aws_ssm_parameter" "ubuntu" {
  name = "/aws/service/canonical/ubuntu/server/22.04/stable/current/amd64/hvm/ebs-gp2/ami-id"
}

resource "aws_vpc" "main" {
  cidr_block           = "192.168.0.0/20"
  enable_dns_hostnames = true
  tags                 = { Name = "VPC-GlobalTech" }
}

resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main.id
}

resource "aws_route_table" "rt" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }
}

resource "aws_subnet" "dep" {
  for_each                = local.subnets
  vpc_id                  = aws_vpc.main.id
  cidr_block              = each.value.cidr
  availability_zone       = "us-east-2a"
  map_public_ip_on_launch = true
  tags                    = { Name = "Subred-${each.key}" }
}

resource "aws_route_table_association" "a" {
  for_each       = aws_subnet.dep
  subnet_id      = each.value.id
  route_table_id = aws_route_table.rt.id
}

resource "aws_security_group" "lab" {
  name   = "sg-lab-redes"
  vpc_id = aws_vpc.main.id

  ingress {
    description = "ICMP interno"
    from_port   = -1
    to_port     = -1
    protocol    = "icmp"
    cidr_blocks = ["192.168.0.0/20"]
  }
  ingress {
    description = "SSH desde EC2 Instance Connect (us-east-2)"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["3.16.146.0/29"]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# ACL (equivalente a la ACL extendida): se aplica en la subred ORIGEN, saliente
resource "aws_network_acl" "administracion" {
  vpc_id     = aws_vpc.main.id
  subnet_ids = [aws_subnet.dep["administracion"].id]

  ingress {
    rule_no    = 100
    action     = "allow"
    protocol   = "-1"
    cidr_block = "0.0.0.0/0"
    from_port  = 0
    to_port    = 0
  }
  egress {
    rule_no    = 100
    action     = "deny"
    protocol   = "-1"
    cidr_block = "192.168.0.0/23"
    from_port  = 0
    to_port    = 0
  }
  egress {
    rule_no    = 110
    action     = "deny"
    protocol   = "-1"
    cidr_block = "192.168.2.0/24"
    from_port  = 0
    to_port    = 0
  }
  egress {
    rule_no    = 200
    action     = "allow"
    protocol   = "-1"
    cidr_block = "0.0.0.0/0"
    from_port  = 0
    to_port    = 0
  }
}

resource "aws_instance" "host" {
  for_each               = { for k, v in local.subnets : k => v if v.host_ip != null }
  ami                    = data.aws_ssm_parameter.ubuntu.value
  instance_type          = "t3.micro"
  subnet_id              = aws_subnet.dep[each.key].id
  private_ip             = each.value.host_ip
  vpc_security_group_ids = [aws_security_group.lab.id]
  tags                   = { Name = "PC-${each.key}" }
}

output "hosts" {
  value = { for k, i in aws_instance.host : k => { privada = i.private_ip, publica = i.public_ip } }
}