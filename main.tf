terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 4.16"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
    null = {
      source  = "hashicorp/null"
      version = "~> 3.0"
    }
    external = {
      source  = "hashicorp/external"
      version = "~> 2.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

# Get next available key name
data "external" "key_check" {
  program = ["${path.module}/scripts/check_key.sh", var.key_name, var.aws_region]
}

locals {
  raw_key_name   = data.external.key_check.result.final_key_name
  final_key_name = replace(local.raw_key_name, " ", "-")
}

# Generate PEM key
resource "tls_private_key" "generated_key" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

# Create EC2 Key Pair
resource "aws_key_pair" "generated_key_pair" {
  key_name   = local.final_key_name
  public_key = tls_private_key.generated_key.public_key_openssh
}

# Upload PEM to S3
resource "aws_s3_object" "upload_pem_key" {
  bucket  = "splunk-deployment-test"
  key     = "${var.usermail}/keys/${local.final_key_name}.pem"
  content = tls_private_key.generated_key.private_key_pem
}

# Save PEM file locally
resource "local_file" "pem_file" {
  filename        = "${path.module}/${local.final_key_name}.pem"
  content         = tls_private_key.generated_key.private_key_pem
  file_permission = "0400"
}

resource "random_id" "sg_suffix" {
  byte_length = 2
}

# Security Groups for each instance
data "aws_ami" "rhel9" {
  most_recent = true

  filter {
    name   = "name"
    values = ["RHEL-9.*x86_64-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }

  owners = ["309956199498"]
}

# Create Distributed Clustered EC2 Instances
resource "aws_instance" "splunk_cluster" {
  count                  = 9
  ami                    = data.aws_ami.rhel9.id
  instance_type          = var.instance_type
  key_name               = aws_key_pair.generated_key_pair.key_name
  vpc_security_group_ids = [aws_security_group.splunk_sg.id]

  root_block_device {
    volume_size = var.storage_size
  }

  user_data = file("scripts/splunk-setup.sh")

  tags = {
    Name          = replace(element(["${var.instance_name}-ClusterMaster", "${var.instance_name}-idx1", "${var.instance_name}-idx2", "${var.instance_name}-idx3", "${var.instance_name}-SH1", "${var.instance_name}-SH2", "${var.instance_name}-SH3", "${var.instance_name}-Management_server", "${var.instance_name}-IF"], count.index), " ", "-")
    AutoStop      = "true"
    Owner         = var.usermail
    UserEmail     = var.usermail
    RunQuotaHours = var.quotahours
    Category      = var.category
    PlanStartDate = var.planstartdate
  }
}

# Security Group
resource "aws_security_group" "splunk_sg" {
  name        = "splunk-security-group-${random_id.sg_suffix.hex}"
  description = "Security group for Splunk server"

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 8000
    to_port     = 9999
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "time_sleep" "wait_10_seconds" {
  depends_on     = [aws_instance.splunk_cluster]
  create_duration = "10s"
}

resource "local_file" "ansible_inventory" {
  depends_on = [time_sleep.wait_10_seconds]
  filename   = "inventory.ini"

  content = join("\n", flatten([
    "[ClusterMaster]",
    "${aws_instance.splunk_cluster[0].tags.Name} ansible_host=${aws_instance.splunk_cluster[0].public_ip} ansible_user=ec2-user private_ip=${aws_instance.splunk_cluster[0].private_ip} ansible_ssh_private_key_file=${abspath("${path.module}/${local.final_key_name}.pem")}\n",

    "[indexers]",
    "${aws_instance.splunk_cluster[1].tags.Name} ansible_host=${aws_instance.splunk_cluster[1].public_ip} ansible_user=ec2-user private_ip=${aws_instance.splunk_cluster[1].private_ip} ansible_ssh_private_key_file=${abspath("${path.module}/${local.final_key_name}.pem")}",
    "${aws_instance.splunk_cluster[2].tags.Name} ansible_host=${aws_instance.splunk_cluster[2].public_ip} ansible_user=ec2-user private_ip=${aws_instance.splunk_cluster[2].private_ip} ansible_ssh_private_key_file=${abspath("${path.module}/${local.final_key_name}.pem")}",
    "${aws_instance.splunk_cluster[3].tags.Name} ansible_host=${aws_instance.splunk_cluster[3].public_ip} ansible_user=ec2-user private_ip=${aws_instance.splunk_cluster[3].private_ip} ansible_ssh_private_key_file=${abspath("${path.module}/${local.final_key_name}.pem")}\n",

    "[SH1]",
    "${aws_instance.splunk_cluster[4].tags.Name} ansible_host=${aws_instance.splunk_cluster[4].public_ip} ansible_user=ec2-user private_ip=${aws_instance.splunk_cluster[4].private_ip} ansible_ssh_private_key_file=${abspath("${path.module}/${local.final_key_name}.pem")}\n",

    "[SH2]",
    "${aws_instance.splunk_cluster[5].tags.Name} ansible_host=${aws_instance.splunk_cluster[5].public_ip} ansible_user=ec2-user private_ip=${aws_instance.splunk_cluster[5].private_ip} ansible_ssh_private_key_file=${abspath("${path.module}/${local.final_key_name}.pem")}\n",

    "[SH3]",
    "${aws_instance.splunk_cluster[6].tags.Name} ansible_host=${aws_instance.splunk_cluster[6].public_ip} ansible_user=ec2-user private_ip=${aws_instance.splunk_cluster[6].private_ip} ansible_ssh_private_key_file=${abspath("${path.module}/${local.final_key_name}.pem")}\n",

    "[search_heads]",
    "${aws_instance.splunk_cluster[4].tags.Name} ansible_host=${aws_instance.splunk_cluster[4].public_ip} ansible_user=ec2-user private_ip=${aws_instance.splunk_cluster[4].private_ip} ansible_ssh_private_key_file=${abspath("${path.module}/${local.final_key_name}.pem")}",
    "${aws_instance.splunk_cluster[5].tags.Name} ansible_host=${aws_instance.splunk_cluster[5].public_ip} ansible_user=ec2-user private_ip=${aws_instance.splunk_cluster[5].private_ip} ansible_ssh_private_key_file=${abspath("${path.module}/${local.final_key_name}.pem")}",
    "${aws_instance.splunk_cluster[6].tags.Name} ansible_host=${aws_instance.splunk_cluster[6].public_ip} ansible_user=ec2-user private_ip=${aws_instance.splunk_cluster[6].private_ip} ansible_ssh_private_key_file=${abspath("${path.module}/${local.final_key_name}.pem")}\n",

    "[Management_server]",
    "${aws_instance.splunk_cluster[7].tags.Name} ansible_host=${aws_instance.splunk_cluster[7].public_ip} ansible_user=ec2-user private_ip=${aws_instance.splunk_cluster[7].private_ip} ansible_ssh_private_key_file=${abspath("${path.module}/${local.final_key_name}.pem")}\n",

    "[IFs]",
    "${aws_instance.splunk_cluster[8].tags.Name} ansible_host=${aws_instance.splunk_cluster[8].public_ip} ansible_user=ec2-user private_ip=${aws_instance.splunk_cluster[8].private_ip} ansible_ssh_private_key_file=${abspath("${path.module}/${local.final_key_name}.pem")}\n",

    "[all_splunk:children]",
    "ClusterMaster",
    "indexers",
    "search_heads",
    "IFs",

    "[all:children]",
    "ClusterMaster",
    "indexers",
    "search_heads",
    "Management_server",
    "IFs"
  ]))
}

resource "local_file" "ansible_group_vars" {
  filename = "group_vars/all.yml"

  content = templatefile("${path.module}/group_vars_template.yml", {
    cluster_master     = [for instance in aws_instance.splunk_cluster : { private_ip = instance.private_ip, instance_id = instance.id } if instance.tags["Name"] == "${var.instance_name}-ClusterMaster"]
    indexers           = { for instance in aws_instance.splunk_cluster : instance.tags["Name"] => { private_ip = instance.private_ip, instance_id = instance.id } if can(regex("${var.instance_name}-idx", instance.tags["Name"])) }
    search_heads       = { for instance in aws_instance.splunk_cluster : instance.tags["Name"] => { private_ip = instance.private_ip, instance_id = instance.id } if can(regex("${var.instance_name}-SH", instance.tags["Name"])) }
    Management_server  = [for instance in aws_instance.splunk_cluster : { private_ip = instance.private_ip, instance_id = instance.id } if instance.tags["Name"] == "${var.instance_name}-Management_server"]
    ifs                = [for instance in aws_instance.splunk_cluster : { private_ip = instance.private_ip, instance_id = instance.id } if instance.tags["Name"] == "${var.instance_name}-IF"]
    splunk_license_url = var.splunk_license_url
    splunk_admin_password = "admin123"
  })
}

output "instance_public_ips" {
  value = {
    for idx, instance in aws_instance.splunk_cluster :
    instance.tags["Name"] => instance.public_ip
  }
}

output "final_key_name" {
  value = local.final_key_name
}

output "s3_key_path" {
  value = "${var.usermail}/keys/${local.final_key_name}.pem"
}
