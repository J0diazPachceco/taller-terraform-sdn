terraform {
  required_version = ">= 1.11"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.0" }
  }
  backend "s3" {
    bucket       = "tfstate-923788823291-us-east-2"
    key          = "parte2-sdn/terraform.tfstate"
    region       = "us-east-2"
    use_lockfile = true
  }
}

provider "aws" {
  region = "us-east-2"
}

data "aws_ssm_parameter" "ubuntu" {
  name = "/aws/service/canonical/ubuntu/server/22.04/stable/current/amd64/hvm/ebs-gp2/ami-id"
}

# Se reutiliza la red creada en la Parte 1
data "aws_vpc" "main" {
  filter {
    name   = "tag:Name"
    values = ["VPC-GlobalTech"]
  }
}

data "aws_subnet" "ingenieria" {
  vpc_id = data.aws_vpc.main.id
  filter {
    name   = "tag:Name"
    values = ["Subred-ingenieria"]
  }
}

resource "aws_security_group" "sdn" {
  name   = "sdn-lab-sg"
  vpc_id = data.aws_vpc.main.id

  ingress {
    description = "ICMP interno"
    from_port   = -1
    to_port     = -1
    protocol    = "icmp"
    cidr_blocks = ["192.168.0.0/20"]
  }
  ingress {
    description = "OpenFlow (Ryu)"
    from_port   = 6653
    to_port     = 6653
    protocol    = "tcp"
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

resource "aws_instance" "ryu" {
  ami                    = data.aws_ssm_parameter.ubuntu.value
  instance_type          = "t3.micro"
  subnet_id              = data.aws_subnet.ingenieria.id
  private_ip             = "192.168.3.20"
  vpc_security_group_ids = [aws_security_group.sdn.id]
  tags                   = { Name = "Ryu-Controlador" }
}

resource "aws_instance" "ovs" {
  ami                    = data.aws_ssm_parameter.ubuntu.value
  instance_type          = "t3.micro"
  subnet_id              = data.aws_subnet.ingenieria.id
  private_ip             = "192.168.3.21"
  vpc_security_group_ids = [aws_security_group.sdn.id]
  tags                   = { Name = "OVS-Switch" }
}

output "servidores" {
  value = {
    ryu = { privada = aws_instance.ryu.private_ip, publica = aws_instance.ryu.public_ip }
    ovs = { privada = aws_instance.ovs.private_ip, publica = aws_instance.ovs.public_ip }
  }
}