<<<<<<< HEAD
data "aws_availability_zones" "available_zones" {
  state = "available"
}


# VPC
resource "aws_vpc" "default" {
  cidr_block = "10.32.0.0/16"
}

# 2 public subnets, 2 private subnets
resource "aws_subnet" "public" {
  count                   = 2
  cidr_block              = cidrsubnet(aws_vpc.default.cidr_block, 8, 2 + count.index)
  availability_zone       = data.aws_availability_zones.available_zones.names[count.index]
  vpc_id                  = aws_vpc.default.id
  map_public_ip_on_launch = true
}

resource "aws_subnet" "private" {
  count             = 2
  cidr_block        = cidrsubnet(aws_vpc.default.cidr_block, 8, count.index)
  availability_zone = data.aws_availability_zones.available_zones.names[count.index]
  vpc_id            = aws_vpc.default.id
  connection {
    type     = "ssh"
    user     = "ec2-user"
    host     = self.public_ip
  }

  provisioner "remote-exec" {
    inline = [
      "sudo yum install -y mysql",
      "mysql -h ${aws_db_instance.mysql.endpoint} -P 3306 -u admin -p${aws_db_instance.mysql.password} -e 'CREATE DATABASE example_db;'",
    ]
  }
}

# SECURITY GROUP FOR MYSQL 

resource "aws_security_group" "mysql" {
  name_prefix = "mysql-sg-"
}

resource "aws_security_group_rule" "mysql_inbound" {
  security_group_id        = aws_security_group.mysql.id
  type                     = "ingress"
  from_port                = 3306
  to_port                  = 3306
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.ec2.id
}


# 4 EC2 Instances
resource "aws_instance" "public_instance" {
  count         = 2
  ami           = "ami-0fcf52bcf5db7b003"
  instance_type = "t2.micro"
  subnet_id     = element(aws_subnet.public.*.id, count.index)

  tags = {
    Name = "public-instance-${count.index}"
  }
}

resource "aws_instance" "private_instance" {
  count         = 2
  ami           = "ami-0fcf52bcf5db7b003"
  instance_type = "t2.micro"
  subnet_id     = element(aws_subnet.private.*.id, count.index)

  tags = {
    Name = "private-instance-${count.index}"
  }
}

# CREATE ECR
resource "aws_ecr_repository" "app_ecr_repo" {
  name = "caduceus-repo"
}



# Internet gateway
resource "aws_internet_gateway" "gateway" {
  vpc_id = aws_vpc.default.id
}

# AWS route
resource "aws_route" "internet_access" {
  route_table_id         = aws_vpc.default.main_route_table_id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.gateway.id
}


# EIP
resource "aws_eip" "gateway" {
  count      = 2
  vpc        = true
  depends_on = [aws_internet_gateway.gateway]
}

# NAT GATEWAY
resource "aws_nat_gateway" "gateway" {
  count         = 2
  subnet_id     = element(aws_subnet.public.*.id, count.index)
  allocation_id = element(aws_eip.gateway.*.id, count.index)
}

# ROUTE TABLE
resource "aws_route_table" "private" {
  count  = 2
  vpc_id = aws_vpc.default.id

  route {
    cidr_block = "0.0.0.0/0"
    nat_gateway_id = element(aws_nat_gateway.gateway.*.id, count.index)
  }
}

resource "aws_route_table_association" "private" {
  count          = 2
  subnet_id      = element(aws_subnet.private.*.id, count.index)
  route_table_id = element(aws_route_table.private.*.id, count.index)
}


#CONFIG

# SECURITY GROUP FOR LOAD BALANCER
resource "aws_security_group" "lb" {
  name        = "alb-security-group"
  vpc_id      = aws_vpc.default.id

  ingress {
    protocol    = "tcp"
    from_port   = 80
    to_port     = 80
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port = 0
    to_port   = 0
    protocol  = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# LOAD BALANCER CONFIGURATION
resource "aws_lb" "default" {
  name            = "caduceus-lb"
  subnets         = aws_subnet.public.*.id
  security_groups = [aws_security_group.lb.id]
}

resource "aws_lb_target_group" "hello_world" {
  name        = "caduceus-lb-target-group"
  port        = 80
  protocol    = "HTTP"
  vpc_id      = aws_vpc.default.id
  target_type = "ip"
}

resource "aws_lb_listener" "hello_world" {
  load_balancer_arn = aws_lb.default.id
  port              = "80"
  protocol          = "HTTP"

  default_action {
    target_group_arn = aws_lb_target_group.hello_world.id
    type             = "forward"
  }
}


# ECS cluster & ECS instance
# ECS task definition
resource "aws_ecs_task_definition" "hello_world" {
  family                   = "caduceus-frontend"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = 1024
  memory                   = 2048

  container_definitions = <<DEFINITION
[
  {
    "image": "342741515821.dkr.ecr.us-west-2.amazonaws.com/app-repo:frontend",
    "cpu": 1024,
    "memory": 2048,
    "name": "caduceus-frontend",
    "networkMode": "awsvpc",
    "portMappings": [
      {
        "containerPort": 3000,
        "hostPort": 3000
      }
    ]
  }
]
DEFINITION
execution_role_arn       = "${aws_iam_role.ecsTaskExecutionRole.arn}"

}
# ----
resource "aws_iam_role" "ecsTaskExecutionRole" {
  name               = "ecsTaskExecutionRoleCaduceus"
  assume_role_policy = "${data.aws_iam_policy_document.assume_role_policy.json}"
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
#-----


resource "aws_security_group" "hello_world_task" {
  name        = "caduceus-security-group"
  vpc_id      = aws_vpc.default.id

  ingress {
    protocol        = "tcp"
    from_port       = 3000
    to_port         = 3000
    security_groups = [aws_security_group.lb.id]
  }

  egress {
    protocol    = "-1"
    from_port   = 0
    to_port     = 0
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_ecs_cluster" "main" {
  name = "caduceus-cluster"
}

resource "aws_ecs_service" "hello_world" {
  name            = "caduceus-service"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.hello_world.arn
  desired_count   = var.app_count
  launch_type     = "FARGATE"

  network_configuration {
    security_groups = [aws_security_group.hello_world_task.id]
    subnets         = aws_subnet.private.*.id
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.hello_world.id
    container_name   = "caduceus-frontend"
    container_port   = 3000
  }

  depends_on = [aws_lb_listener.hello_world]
}

output "load_balancer_ip" {
  value = aws_lb.default.dns_name
}

# Connect EC2 to RDS Mysql community 
resource "aws_security_group_rule" "ec2_inbound" {
  security_group_id = aws_security_group.ec2.id
  type              = "ingress"
  from_port         = 3306
  to_port           = 3306
  protocol          = "tcp"
  cidr_blocks       = ["0.0.0.0/0"]
}

resource "aws_db_instance" "mysql" {
  allocated_storage    = 20
  engine               = "mysql"
  engine_version       = "5.7"
  instance_class       = "db.t2.micro"
  name                 = "example-mysql"
  username             = "admin"
  password             = "password"
  parameter_group_name = "default.mysql5.7"
  skip_final_snapshot  = true

  vpc_security_group_ids = [
    aws_security_group.mysql.id,
  ]

  tags = {
    Name = "caduceus-mysql"
  }
}
=======
data "aws_availability_zones" "available_zones" {
  state = "available"
}


# VPC
resource "aws_vpc" "default" {
  cidr_block = "10.32.0.0/16"
}

# 2 public subnets, 2 private subnets
resource "aws_subnet" "public" {
  count                   = 2
  cidr_block              = cidrsubnet(aws_vpc.default.cidr_block, 8, 2 + count.index)
  availability_zone       = data.aws_availability_zones.available_zones.names[count.index]
  vpc_id                  = aws_vpc.default.id
  map_public_ip_on_launch = true
}

resource "aws_subnet" "private" {
  count             = 2
  cidr_block        = cidrsubnet(aws_vpc.default.cidr_block, 8, count.index)
  availability_zone = data.aws_availability_zones.available_zones.names[count.index]
  vpc_id            = aws_vpc.default.id
  connection {
    type     = "ssh"
    user     = "ec2-user"
    host     = self.public_ip
  }

  provisioner "remote-exec" {
    inline = [
      "sudo yum install -y mysql",
      "mysql -h ${aws_db_instance.mysql.endpoint} -P 3306 -u admin -p${aws_db_instance.mysql.password} -e 'CREATE DATABASE example_db;'",
    ]
  }
}

# SECURITY GROUP FOR MYSQL 

resource "aws_security_group" "mysql" {
  name_prefix = "mysql-sg-"
}

resource "aws_security_group_rule" "mysql_inbound" {
  security_group_id        = aws_security_group.mysql.id
  type                     = "ingress"
  from_port                = 3306
  to_port                  = 3306
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.ec2.id
}


# 4 EC2 Instances
resource "aws_instance" "public_instance" {
  count         = 2
  ami           = "ami-0fcf52bcf5db7b003"
  instance_type = "t2.micro"
  subnet_id     = element(aws_subnet.public.*.id, count.index)

  tags = {
    Name = "public-instance-${count.index}"
  }
}

resource "aws_instance" "private_instance" {
  count         = 2
  ami           = "ami-0fcf52bcf5db7b003"
  instance_type = "t2.micro"
  subnet_id     = element(aws_subnet.private.*.id, count.index)

  tags = {
    Name = "private-instance-${count.index}"
  }
}

# CREATE ECR
resource "aws_ecr_repository" "app_ecr_repo" {
  name = "caduceus-repo"
}



# Internet gateway
resource "aws_internet_gateway" "gateway" {
  vpc_id = aws_vpc.default.id
}

# AWS route
resource "aws_route" "internet_access" {
  route_table_id         = aws_vpc.default.main_route_table_id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.gateway.id
}


# EIP
resource "aws_eip" "gateway" {
  count      = 2
  vpc        = true
  depends_on = [aws_internet_gateway.gateway]
}

# NAT GATEWAY
resource "aws_nat_gateway" "gateway" {
  count         = 2
  subnet_id     = element(aws_subnet.public.*.id, count.index)
  allocation_id = element(aws_eip.gateway.*.id, count.index)
}

# ROUTE TABLE
resource "aws_route_table" "private" {
  count  = 2
  vpc_id = aws_vpc.default.id

  route {
    cidr_block = "0.0.0.0/0"
    nat_gateway_id = element(aws_nat_gateway.gateway.*.id, count.index)
  }
}

resource "aws_route_table_association" "private" {
  count          = 2
  subnet_id      = element(aws_subnet.private.*.id, count.index)
  route_table_id = element(aws_route_table.private.*.id, count.index)
}


#CONFIG

# SECURITY GROUP FOR LOAD BALANCER
resource "aws_security_group" "lb" {
  name        = "alb-security-group"
  vpc_id      = aws_vpc.default.id

  ingress {
    protocol    = "tcp"
    from_port   = 80
    to_port     = 80
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port = 0
    to_port   = 0
    protocol  = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# LOAD BALANCER CONFIGURATION
resource "aws_lb" "default" {
  name            = "caduceus-lb"
  subnets         = aws_subnet.public.*.id
  security_groups = [aws_security_group.lb.id]
}

resource "aws_lb_target_group" "hello_world" {
  name        = "caduceus-lb-target-group"
  port        = 80
  protocol    = "HTTP"
  vpc_id      = aws_vpc.default.id
  target_type = "ip"
}

resource "aws_lb_listener" "hello_world" {
  load_balancer_arn = aws_lb.default.id
  port              = "80"
  protocol          = "HTTP"

  default_action {
    target_group_arn = aws_lb_target_group.hello_world.id
    type             = "forward"
  }
}


# ECS cluster & ECS instance
# ECS task definition
resource "aws_ecs_task_definition" "hello_world" {
  family                   = "caduceus-frontend"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = 1024
  memory                   = 2048

  container_definitions = <<DEFINITION
[
  {
    "image": "342741515821.dkr.ecr.us-west-2.amazonaws.com/app-repo:frontend",
    "cpu": 1024,
    "memory": 2048,
    "name": "caduceus-frontend",
    "networkMode": "awsvpc",
    "portMappings": [
      {
        "containerPort": 3000,
        "hostPort": 3000
      }
    ]
  }
]
DEFINITION
execution_role_arn       = "${aws_iam_role.ecsTaskExecutionRole.arn}"

}
# ----
resource "aws_iam_role" "ecsTaskExecutionRole" {
  name               = "ecsTaskExecutionRoleCaduceus"
  assume_role_policy = "${data.aws_iam_policy_document.assume_role_policy.json}"
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
#-----


resource "aws_security_group" "hello_world_task" {
  name        = "caduceus-security-group"
  vpc_id      = aws_vpc.default.id

  ingress {
    protocol        = "tcp"
    from_port       = 3000
    to_port         = 3000
    security_groups = [aws_security_group.lb.id]
  }

  egress {
    protocol    = "-1"
    from_port   = 0
    to_port     = 0
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_ecs_cluster" "main" {
  name = "caduceus-cluster"
}

resource "aws_ecs_service" "hello_world" {
  name            = "caduceus-service"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.hello_world.arn
  desired_count   = var.app_count
  launch_type     = "FARGATE"

  network_configuration {
    security_groups = [aws_security_group.hello_world_task.id]
    subnets         = aws_subnet.private.*.id
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.hello_world.id
    container_name   = "caduceus-frontend"
    container_port   = 3000
  }

  depends_on = [aws_lb_listener.hello_world]
}

output "load_balancer_ip" {
  value = aws_lb.default.dns_name
}

# Connect EC2 to RDS Mysql community 
resource "aws_security_group_rule" "ec2_inbound" {
  security_group_id = aws_security_group.ec2.id
  type              = "ingress"
  from_port         = 3306
  to_port           = 3306
  protocol          = "tcp"
  cidr_blocks       = ["0.0.0.0/0"]
}

resource "aws_db_instance" "mysql" {
  allocated_storage    = 20
  engine               = "mysql"
  engine_version       = "5.7"
  instance_class       = "db.t2.micro"
  name                 = "example-mysql"
  username             = "admin"
  password             = "password"
  parameter_group_name = "default.mysql5.7"
  skip_final_snapshot  = true

  vpc_security_group_ids = [
    aws_security_group.mysql.id,
  ]

  tags = {
    Name = "caduceus-mysql"
  }
}
>>>>>>> f4d9de8d1958a9b2bba5c93591434da17fb68ca4
