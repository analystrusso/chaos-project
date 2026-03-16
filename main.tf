data "aws_ami" "ubuntu" {
  most_recent = true

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }

  owners = ["099720109477"] # Canonical
}

resource "aws_vpc" "chaos-vpc" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true
}

resource "aws_subnet" "chaos-subnet" {
  vpc_id                  = aws_vpc.chaos-vpc.id
  cidr_block              = var.subnet_cidr
  map_public_ip_on_launch = true
}

resource "aws_internet_gateway" "chaos-igw" {
  vpc_id = aws_vpc.chaos-vpc.id
}

resource "aws_route_table" "chaos-rt" {
  vpc_id = aws_vpc.chaos-vpc.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.chaos-igw.id
  }
}

resource "aws_route_table_association" "chaos-rta" {
  subnet_id      = aws_subnet.chaos-subnet.id
  route_table_id = aws_route_table.chaos-rt.id
}

resource "tls_private_key" "chaos-key" {
  algorithm = "ED25519"
}

resource "aws_key_pair" "chaos-keypair" {
  key_name   = "chaos-keypair"
  public_key = tls_private_key.chaos-key.public_key_openssh
}

resource "local_file" "chaos-pem" {
  content         = tls_private_key.chaos-key.private_key_openssh
  filename        = "${path.module}/chaos-keypair.pem"
  file_permission = "0400"
}

resource "aws_instance" "chaos-master" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = "t3.small"
  key_name               = aws_key_pair.chaos-keypair.key_name
  subnet_id              = aws_subnet.chaos-subnet.id
  vpc_security_group_ids = [aws_security_group.chaos-sg.id]
  user_data              = file("user-data/master.sh")
  tags                   = { Name = "chaos-master" }
}

resource "aws_instance" "chaos-worker" {
  count                  = 2
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = "t3.small"
  key_name               = aws_key_pair.chaos-keypair.key_name
  subnet_id              = aws_subnet.chaos-subnet.id
  vpc_security_group_ids = [aws_security_group.chaos-sg.id]
  user_data              = file("user-data/worker.sh")
  tags                   = { Name = "chaos-worker-${count.index}" }
}

resource "aws_security_group" "chaos-sg" {
  name = "papers_please"
  description = "Allow inbound and outbound traffic according to rules."
  vpc_id = aws_vpc.chaos-vpc.id

  tags = {
    Name = "chaos-sg"
  }
}

resource "aws_vpc_security_group_ingress_rule" "chaos-sg-ssh" {
  security_group_id = aws_security_group.chaos-sg.id
  cidr_ipv4         = var.my_ip
  from_port         = 22
  ip_protocol       = "tcp"
  to_port           = 22
}

resource "aws_vpc_security_group_ingress_rule" "chaos-sg-k3s" {
  security_group_id = aws_security_group.chaos-sg.id
  cidr_ipv4         = aws_vpc.chaos-vpc.cidr_block
  from_port         = 6443
  ip_protocol       = "tcp"
  to_port           = 6443
}

resource "aws_vpc_security_group_ingress_rule" "chaos-sg-kubelet" {
  security_group_id = aws_security_group.chaos-sg.id
  cidr_ipv4         = aws_vpc.chaos-vpc.cidr_block
  from_port         = 10250
  ip_protocol       = "tcp"
  to_port           = 10250
}

resource "aws_vpc_security_group_ingress_rule" "chaos-sg-flannel" {
  security_group_id = aws_security_group.chaos-sg.id
  cidr_ipv4         = aws_vpc.chaos-vpc.cidr_block
  from_port         = 8472
  ip_protocol       = "udp"
  to_port           = 8472
}

resource "aws_vpc_security_group_ingress_rule" "chaos-sg-etcd" {
  security_group_id = aws_security_group.chaos-sg.id
  cidr_ipv4         = aws_vpc.chaos-vpc.cidr_block
  from_port         = 2379
  ip_protocol       = "tcp"
  to_port           = 2380
}

resource "aws_vpc_security_group_ingress_rule" "chaos-sg-dashboard" {
  security_group_id = aws_security_group.chaos-sg.id
  cidr_ipv4         = var.my_ip
  from_port         = 2333
  ip_protocol       = "tcp"
  to_port           = 2333
}

resource "aws_vpc_security_group_egress_rule" "chaos-sg-egress" {
  security_group_id = aws_security_group.chaos-sg.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

