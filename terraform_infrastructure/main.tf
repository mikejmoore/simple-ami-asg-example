################################################################################
#  AWS provider tells Terraform how to connect to your AWS account.
################################################################################

provider "aws" {
  access_key = "${var.aws_access_key}"
  secret_key = "${var.aws_secret_key}"
  region     = "${var.aws_region}"
}

################################################################################
#  Find a reference to the nginx AMI we created with Packer.
################################################################################

data "aws_ami" "nginx" {
  most_recent = true
  filter {
    name   = "tag:environment"
    values = ["testing"]
  }
  filter {
    name   = "tag:service"
    values = ["nginx"]
  }
  owners     = ["self"]
}

################################################################################
#  Set up a VPC and Subnets for our infrastucture.
################################################################################

resource "aws_vpc" "main" {
  cidr_block       = "10.0.0.0/16"
  tags {
    Name = "example-vpc"
  }
}

################################################################################
#  Gateway to/from internet.
################################################################################

resource "aws_internet_gateway" "gw" {
  vpc_id      = "${aws_vpc.main.id}"
  tags {
    Name           = "example-1-igw"
    environment    = "example-1"
    service        = "internet-gateway"
  }
}

################################################################################
#  Subnets and routing.
################################################################################

resource "aws_route_table" "public" {
  vpc_id    = "${aws_vpc.main.id}"
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = "${aws_internet_gateway.gw.id}"
  }
  tags {
    Name           = "example-1-routes"
    environment    = "example-1"
    service        = "route-table"
  }
}

resource "aws_subnet" "example-subnet-1" {
  vpc_id            = "${aws_vpc.main.id}"
  availability_zone = "${var.aws_region}a"
  cidr_block        = "${cidrsubnet(aws_vpc.main.cidr_block, 4, 1)}"
  tags {
    Name          = "example-1-subnet-az-a"
    environment   = "example-1"
  }
}

resource "aws_route_table_association" "subnet-1" {
  subnet_id         = "${aws_subnet.example-subnet-1.id}"
  route_table_id    = "${aws_route_table.public.id}"
}

resource "aws_subnet" "example-subnet-2" {
  vpc_id            = "${aws_vpc.main.id}"
  availability_zone = "${var.aws_region}b"
  cidr_block        = "${cidrsubnet(aws_vpc.main.cidr_block, 4, 2)}"
  tags {
    Name          = "example-1-subnet-az-b"
    environment   = "example-1"
  }
}

resource "aws_route_table_association" "subnet-2" {
  subnet_id         = "${aws_subnet.example-subnet-2.id}"
  route_table_id    = "${aws_route_table.public.id}"
}

################################################################################
#  Security group for the nginx ec2 instances.
#   * Allows SSH from anywhere.
#   * Allows port 80 HTTP only from within the VPC.
################################################################################

resource "aws_security_group" "nginx_instance" {
  name        = "example-1-nginx-instance-sec-group"
  vpc_id      = "${aws_vpc.main.id}"
  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["${aws_vpc.main.cidr_block}"]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags {
    Name          = "example-1-nginx-instance-sec-group"
    service       = "nginx"
    environment   = "example-1"
  }
}

################################################################################
#  Create the autoscaling group and launch configuration.
#    * The launch configuration uses the AMI we created for Nginx.
#    * The launch configuration also installs a user_data script that performs
#      self-initializing as the instance starts up.
################################################################################

resource "aws_launch_configuration" "nginx" {
  name          = "example-1-launch-group"
  image_id      = "${data.aws_ami.nginx.id}"
  instance_type = "t2.micro"
  user_data     = "${file("./files/user_data.sh")}"
  security_groups = ["${aws_security_group.nginx_instance.id}"]
  associate_public_ip_address = true
  key_name            = "${var.key_pair}"
}

resource "aws_autoscaling_group" "nginx" {
  availability_zones        = ["${var.aws_region}a", "${var.aws_region}b"]
  name                      = "example-1-asg"
  max_size                  = 3
  min_size                  = 2
  health_check_grace_period = 300
  health_check_type         = "ELB"
  desired_capacity          = 2
  force_delete              = true
  launch_configuration      = "${aws_launch_configuration.nginx.name}"
  target_group_arns         = ["${aws_alb_target_group.nginx.id}"]
  vpc_zone_identifier       = ["${aws_subnet.example-subnet-1.id}", "${aws_subnet.example-subnet-2.id}"]
}

################################################################################
#  Security group to allow internet users into the nginx cluster for http.
################################################################################

resource "aws_security_group" "nginx_load_balancer" {
  name        = "example-1-nginx-alb-sec-group"
  vpc_id      = "${aws_vpc.main.id}"
  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags {
    Name          = "example-1-nginx-alb-sec-group"
    service       = "nginx"
    environment   = "example-1"
  }
}

################################################################################
#  Place Load Balancer in front of Nginx cluster
################################################################################

resource "aws_alb" "nginx" {
  name              = "nginx-load-balancer"
  subnets           = ["${aws_subnet.example-subnet-1.id}", "${aws_subnet.example-subnet-2.id}"]
  security_groups   = ["${aws_security_group.nginx_load_balancer.id}"]
  internal          = false
  tags {
    environment = "example-1"
    service     = "nginx"
    component   = "alb"
  }
}

################################################################################
#  Load Balancer needs a target group that tracks Ec2's and checks their health.
################################################################################

resource "aws_alb_target_group" "nginx" {
  name        = "nginx-target-group"
  port        = 80
  protocol    = "HTTP"
  vpc_id      = "${aws_vpc.main.id}"
  health_check {
    port      = 80
    matcher   = "200-210"
  }
}

################################################################################
#  Load Balancer listens on port 80.
################################################################################
resource "aws_alb_listener" "nginx" {
  load_balancer_arn   = "${aws_alb.nginx.arn}"
  port                = "80"
  protocol            = "HTTP"
  default_action {
    target_group_arn  = "${aws_alb_target_group.nginx.arn}"
    type              = "forward"
  }
}
