
provider "aws" {
  version             = "2.0.0"
  region="ap-southeast-2"
}


variable "dnsname" {
  type="string"
  default=""
}

// Legacy variable to support user's pre-created ACM cert.
variable "ACM_CERT" {
  type="string"
  default = ""
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
### ACM validation
resource "aws_acm_certificate" "cert" {
  domain_name       = "${var.dnsname}"
  validation_method = "DNS"
}

resource "aws_acm_certificate_validation" "cert" {
  certificate_arn = "${aws_acm_certificate.cert.arn}"
  timeouts {
    create = "10m"
  }
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

module "web_server_sg_80" {
  source = "terraform-aws-modules/security-group/aws//modules/http-80"

  name        = "${var.name}-web-server-80"
  description = "Security group for web-server"
  vpc_id      = "${module.vpc.vpc_id}"

  ingress_cidr_blocks = ["0.0.0.0/0"]
  tags = {
    Terraform = "true"
  }
}

module "web_server_sg_443" {
  source = "terraform-aws-modules/security-group/aws//modules/https-443"

  name        = "${var.name}-web-server-443"
  description = "Security group for web-server"
  vpc_id      = "${module.vpc.vpc_id}"

  ingress_cidr_blocks = ["0.0.0.0/0"]
  tags = {
    Terraform = "true"
  }
}

### Create database
module "db" {
  source = "terraform-aws-modules/rds/aws"

  identifier = "democtf"

  engine            = "mysql"
  engine_version    = "5.7.19"
  instance_class    = "db.t2.micro"
  allocated_storage = 5

  name     = "democtf"
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


### ALB

resource "aws_alb" "main" {
  name            = "tf-ecs-chat"
  subnets         = ["${module.vpc.public_subnets[0]}","${module.vpc.public_subnets[1]}"]
   security_groups = [
     "${module.web_server_sg_443.this_security_group_id}",
    "${module.web_server_sg_80.this_security_group_id}"
    ]
  tags = {
    Terraform = "true"
  }
}

resource "aws_alb_target_group" "app" {
  name        = "tf-ecs-chat"
  port        = 443
  protocol    = "HTTPS"
  vpc_id      = "${module.vpc.vpc_id}"
  target_type = "ip"
  health_check = {
    protocol = "HTTPS"
    unhealthy_threshold  = 3
    interval = 60
    timeouts = 10
  }
  tags = {
    Terraform = "true"
  }
}

# Redirect all traffic from the ALB to the target group
resource "aws_alb_listener" "front_end" {
  load_balancer_arn = "${aws_alb.main.arn}"
  port              = "443"
  protocol          = "HTTPS"
  certificate_arn   = "${aws_acm_certificate_validation.cert.certificate_arn}"

  default_action {
    target_group_arn = "${aws_alb_target_group.app.arn}"
    type             = "forward"
  }
}

resource "aws_lb_listener_certificate" "customcert" {
  count = "${var.ACM_CERT != "" ? 1 : 0}"
  listener_arn    = "${aws_alb_listener.front_end.arn}"
  certificate_arn = "${var.ACM_CERT}"
}


resource "aws_lb_listener" "front_end_redirect" {
  load_balancer_arn = "${aws_alb.main.arn}"
  port              = "80"
  protocol          = "HTTP"

  default_action {
    type = "redirect"

    redirect {
      port        = "443"
      protocol    = "HTTPS"
      status_code = "HTTP_301"
    }
  }

}



### Memcached


resource "aws_elasticache_subnet_group" "main" {
  name       = "${var.name}-cache-subnet"
  subnet_ids = ["${module.vpc.private_subnets}"]
}             


// For PoC we are using 1 memcached node only - in the future we want a route53 internal zone with CNAME to all nodes.
resource "aws_elasticache_cluster" "main" {
  cluster_id           = "${var.name}-memcached"
  engine               = "memcached"
  node_type            = "cache.m4.large"
  num_cache_nodes      = 1
  parameter_group_name = "default.memcached1.4"
  port                 = 11211
  subnet_group_name = "${aws_elasticache_subnet_group.main.name}"
  tags = {
    Terraform = "true"
  }
}


### ECS

# https://docs.aws.amazon.com/AmazonECS/latest/developerguide/task_execution_IAM_role.html
resource "aws_iam_role" "ecsTaskExecutionRole" {
  name               = "${var.name}-execution-role-ecs"
  assume_role_policy = "${data.aws_iam_policy_document.assume_role_policy.json}"
  tags = {
    Terraform = "true"
  }
}

data "aws_iam_policy_document" "assume_role_policy" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role_policy_attachment" "ecsTaskExecutionRole_policy" {
  role       = "${aws_iam_role.ecsTaskExecutionRole.name}"
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_ecs_cluster" "main" {
  name = "${var.name}-ecs-cluster"
  tags = {
    Terraform = "true"
  }
}

resource "aws_cloudwatch_log_group" "log_group" {
  name = "ecs-${var.name}"
}


# ECS task definition has an important envrionment variable called "RESET_DB". If this environment variable is set, the ECS task will attempt to reset the db to default with admin/password login
# We only need to do this once and then change the environment variable to be something else eg DONT_RESET_DB so subsequent deployment will not reset the db.
resource "aws_ecs_task_definition" "app" {
  family                   = "${var.name}"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = "1024"
  memory                   = "4096"
  execution_role_arn       = "${aws_iam_role.ecsTaskExecutionRole.arn}"
  container_definitions = <<DEFINITION
[
    {
      "logConfiguration": {
        "logDriver": "awslogs",
        "options": {
          "awslogs-group": "${aws_cloudwatch_log_group.log_group.name}",
          "awslogs-region": "ap-southeast-2",
          "awslogs-stream-prefix": "ecs"
        }
      },
      "entryPoint": [
        "/root/extra/service_startup.sh"
      ],
      "portMappings": [
        {
          "hostPort": 80,
          "protocol": "tcp",
          "containerPort": 80
        },
        {
          "hostPort": 443,
          "protocol": "tcp",
          "containerPort": 443
        }
      ],
      "cpu": 800,
      "environment": [
        {
          "name": "DB_HOST",
          "value": "${module.db.this_db_instance_address}"
        },
        {
          "name": "DB_NAME",
          "value": "fbctf"
        },
        {
          "name": "DB_PASSWORD",
          "value": "${var.RDS_PASSWORD}"
        },
        {
          "name": "DB_USER",
          "value": "${var.RDS_USERNAME}"
        },
        {
          "name": "DONT_RESET_DB",
          "value": "true"
        }
      ],
      "workingDirectory": "/root",
      "memory": 4000,
      "memoryReservation": 2098,
      "image": "registry.hub.docker.com/santrancisco/sanctf:remote",
      "essential": true,
      "name": "${var.name}"
    }
  ]
DEFINITION
  tags = {
    Terraform = "true"
  }
}


resource "aws_ecs_service" "main" {
  name            = "${var.name}-ecs-service"
  cluster         = "${aws_ecs_cluster.main.id}"
  task_definition = "${aws_ecs_task_definition.app.arn}"
  desired_count   = "1"
  launch_type     = "FARGATE"

  network_configuration {
    assign_public_ip         = "true"
    security_groups = ["${module.mysql_security_group.this_security_group_id}",
    "${module.web_server_sg_443.this_security_group_id}",
    "${module.web_server_sg_80.this_security_group_id}"]
    subnets         = ["${module.vpc.private_subnets}"]
  }

  load_balancer {
    target_group_arn = "${aws_alb_target_group.app.id}"
    container_name   = "${var.name}"
    container_port   = "443"
  }

  depends_on = [
    "aws_alb_listener.front_end",
  ]
  tags = {
    Terraform = "true"
  }
}
