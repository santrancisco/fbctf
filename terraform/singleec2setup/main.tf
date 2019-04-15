
provider "aws" {
  version             = "2.0.0"
  region="ap-southeast-2"
}

variable "databasename" {
  type="string"
  default="democtf"
}


variable "dnsname" {
  type="string"
  default="ctf.ebfe.pw"
}

variable "key_name" {
  type="string"
  description="The name of the ssh key pair we use to manage the cluster."
} 


data "aws_ami" "ubuntu" {
    most_recent = true

    filter {
        name   = "name"
        values = ["ubuntu/images/hvm-ssd/ubuntu-xenial-16.04-amd64-server-*"]
    }

    filter {
        name   = "virtualization-type"
        values = ["hvm"]
    }

    owners = ["099720109477"] # Canonical
}

variable "name"{
    default = "ctf"
}
variable "RDS_USERNAME" {
    type = "string"
}
variable "RDS_PASSWORD" {
    type = "string"
}



### Plumbing network
module "vpc" {
  source = "terraform-aws-modules/vpc/aws"

  name = "my-vpc"
  cidr = "10.0.0.0/16"

  azs             = ["ap-southeast-2a", "ap-southeast-2b"]
  private_subnets = ["10.0.1.0/24", "10.0.2.0/24"]
  public_subnets  = ["10.0.101.0/24", "10.0.102.0/24"]

  enable_nat_gateway = false
  enable_vpn_gateway = false

  tags = {
    Terraform = "true"
  }
}

module "mysql_security_group" {
  source = "terraform-aws-modules/security-group/aws//modules/mysql"
  name        = "${var.name}-mysql"
  vpc_id = "${module.vpc.vpc_id}"
  ingress_cidr_blocks = ["${module.vpc.vpc_cidr_block}"]
  tags = {
    Terraform = "true"
  }
}

module "web_server_sg" {
  source = "terraform-aws-modules/security-group/aws"
  vpc_id      = "${module.vpc.vpc_id}"

  name        = "${var.name}-web-server"
  description = "Security group for web-server"
  
  ingress_rules            = ["https-443-tcp","http-80-tcp","ssh-tcp","all-icmp"]
  ingress_cidr_blocks = ["0.0.0.0/0"]
  tags = {
    Terraform = "true"
  }
  egress_rules = [ "all-all" ]
  egress_cidr_blocks = ["0.0.0.0/0"]

}

### Create database
## CHange instance type to bigger one when running the event
module "db" {
  source = "terraform-aws-modules/rds/aws"

  identifier = "democtf"

  engine            = "mysql"
  engine_version    = "5.7.19"
  instance_class    = "db.t2.micro"
  allocated_storage = 5

  name     = "${var.databasename}"
  username = "${var.RDS_USERNAME}"
  password = "${var.RDS_PASSWORD}"
  port     = "3306"

  iam_database_authentication_enabled = true

  vpc_security_group_ids = ["${module.mysql_security_group.this_security_group_id}"]

  maintenance_window = "Mon:00:00-Mon:03:00"
  backup_window      = "03:00-06:00"

  # DB subnet group
  subnet_ids = ["${module.vpc.private_subnets[0]}","${module.vpc.private_subnets[1]}"]

  # DB parameter group
  family = "mysql5.7"

  # DB option group
  major_engine_version = "5.7"

  # Snapshot name upon DB deletion
  final_snapshot_identifier = "democtf"

  # Database Deletion Protection
  deletion_protection = false

  parameters = [
    {
      name = "character_set_client"
      value = "utf8"
    },
    {
      name = "character_set_server"
      value = "utf8"
    }
  ]
  tags = {
    Terraform = "true"
  }
}


### Create EC2 instance
## CHange instance type to bigger one when running the event
## When choosing instance type - remember at least 1gb of ram and be a little generous.
module "ec2" {
  source =   "terraform-aws-modules/ec2-instance/aws"
  name                   = "fbctf"
  subnet_id      = "${module.vpc.public_subnets[0]}"
  associate_public_ip_address = true

  ami = "${data.aws_ami.ubuntu.id}"
  instance_type = "m4.large"
  key_name = "${var.key_name}"
  monitoring = true
  vpc_security_group_ids = ["${module.web_server_sg.this_security_group_id}"]
  user_data= <<EOF
#!/bin/bash
set -ex
apt-get update
apt-get install -y git htop
apt-get install -y apt-utils mysql-client
mkdir /opt || true
cd /opt
git clone --depth 1 https://github.com/santrancisco/fbctf.git
cd fbctf
sudo sed -i 's/fbctf/${var.databasename}/g' /opt/fbctf/database/schema.sql

mkdir -p /tmp/composer
export COMPOSER_HOME=/tmp/composer
export EXITIMMEDIATELY=true
export DB_SCHEMA_PATH=/opt/fbctf/database
export DB_HOST=${module.db.this_db_instance_address}
export DB_NAME=${var.databasename}
export DB_PASSWORD=${var.RDS_PASSWORD}
export DB_USER=${var.RDS_USERNAME}
export RESET_DB=true
# Use line below for self signed cert and not generating certbot.sh
# ./extra/provision.sh -m  prod -c self -s /opt/fbctf
./extra/provision.sh -m  prod -c certbot -s /opt/fbctf -D ${var.dnsname}
./extra/service_startup.sh

EOF
}
 