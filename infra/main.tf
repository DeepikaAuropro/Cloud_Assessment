# VPC
resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true
}

# Subnets
resource "aws_subnet" "public" {
  count                   = length(var.availability_zones)
  vpc_id                  = aws_vpc.main.id
  cidr_block              = cidrsubnet(var.vpc_cidr, 4, count.index)
  map_public_ip_on_launch = true
  availability_zone       = element(var.availability_zones, count.index)
}

resource "aws_subnet" "private" {
  count             = length(var.availability_zones)
  vpc_id            = aws_vpc.main.id
  cidr_block        = cidrsubnet(var.vpc_cidr, 4, count.index + length(var.availability_zones))
  availability_zone = element(var.availability_zones, count.index)
}

# Internet Gateway
resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main.id
}

# Elastic IP for NAT Gateway
resource "aws_eip" "nat" {
  count = length(aws_subnet.public)
}

# NAT Gateway
resource "aws_nat_gateway" "nat" {
  count         = length(aws_subnet.public)
  allocation_id = aws_eip.nat[count.index].id
  subnet_id     = aws_subnet.public[count.index].id
}

# Public Route Table
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
}

resource "aws_route" "public_internet_access" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.igw.id
}

resource "aws_route_table_association" "public" {
  count          = length(aws_subnet.public)
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# Separate Private Route Tables for each subnet
resource "aws_route_table" "private" {
  count = length(aws_subnet.private)
  vpc_id = aws_vpc.main.id
}

resource "aws_route" "private_nat_access" {
  count = length(aws_subnet.private)
  route_table_id         = aws_route_table.private[count.index].id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.nat[count.index].id

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_route_table_association" "private" {
  count          = length(aws_subnet.private)
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private[count.index].id
}

# Security Groups
resource "aws_security_group" "ec2" {
  vpc_id = aws_vpc.main.id

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
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 443
    to_port     = 443
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

resource "aws_security_group" "rds" {
  vpc_id = aws_vpc.main.id

  ingress {
    from_port   = 3306
    to_port     = 3306
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# EC2 Instances
resource "aws_instance" "ssm_host" {
  ami           = var.ami_id
  instance_type = "t2.micro"
  subnet_id     = element(aws_subnet.public[*].id, 0)
  security_groups = [aws_security_group.ec2.id]

  tags = {
    Name = "SSM Host"
  }
}

resource "aws_instance" "app_server" {
  ami           = var.ami_id
  instance_type = "t2.micro"
  subnet_id     = element(aws_subnet.private[*].id, 0)
  security_groups = [aws_security_group.ec2.id]

  tags = {
    Name = "App Server"
  }
}

# RDS MariaDB
resource "aws_db_subnet_group" "main" {
  name       = "main"
  subnet_ids = aws_subnet.private[*].id

  tags = {
    Name = "My DB subnet group"
  }
}

resource "aws_db_instance" "myrds" {
  engine               = "mariadb"
  identifier           = "myrds"
  allocated_storage    =  20
  engine_version       = "10.11.6"  # Adjusted to a valid version
  instance_class       = "db.m5.large"
  username             = var.db_username
  password             = var.db_password
  db_subnet_group_name = aws_db_subnet_group.main.name
  skip_final_snapshot  = true
  multi_az             = true
  publicly_accessible  = true
  vpc_security_group_ids = [aws_security_group.rds.id]

  tags = {
    Name = "RDS Master"
  }
}

# IAM Role for EC2 instances in Auto Scaling Group
resource "aws_iam_role" "ec2_role" {
  name = "ec2-role-for-rds-access"

  assume_role_policy = jsonencode({
    "Version" : "2012-10-17",
    "Statement" : [{
      "Effect" : "Allow",
      "Principal" : {
        "Service" : "ec2.amazonaws.com"
      },
      "Action" : "sts:AssumeRole"
    }]
  })
}

# IAM Policy for RDS Access
resource "aws_iam_policy" "rds_policy" {
  name        = "rds-policy-for-ec2-instances"
  description = "IAM policy to allow EC2 instances to access RDS"
  
  policy = jsonencode({
    "Version": "2012-10-17",
    "Statement": [{
      "Effect": "Allow",
      "Action": "rds-db:connect",
      "Resource": "*"
    }]
  })
}

# IAM Role Policy Attachment
resource "aws_iam_role_policy_attachment" "rds_access" {
  role       = aws_iam_role.ec2_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonRDSFullAccess"  # Or use your custom policy ARN
}

resource "aws_launch_configuration" "ec2_launch_configuration" {
  name_prefix          = "example-"
  image_id             = var.ami_id
  instance_type        = "t2.micro"
  security_groups      = [aws_security_group.ec2.id]
  lifecycle {
    create_before_destroy = true
  }
}


# Autoscaling group in the private subnet where RDS master instance is created
resource "aws_autoscaling_group" "ec2_autoscaling_group" {
  desired_capacity     = 2
  min_size             = 1
  max_size             = 5
  launch_configuration = aws_launch_configuration.ec2_launch_configuration.name
  vpc_zone_identifier  = [aws_subnet.private[0].id]
}

# Modify EC2 instances security groups to allow access to RDS instances
resource "aws_security_group_rule" "ec2_to_rds" {
  type              = "ingress"
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  security_group_id = aws_security_group.rds.id
  source_security_group_id = aws_security_group.ec2.id
}

# S3 Bucket and CloudFront
resource "aws_s3_bucket" "bucket" {
  bucket = var.s3_bucket_name
}

resource "aws_s3_bucket_ownership_controls" "owner" {
  bucket = aws_s3_bucket.bucket.id
  rule {
    object_ownership = "BucketOwnerPreferred"
  }
}

resource "aws_s3_bucket_acl" "acl" {
  depends_on = [aws_s3_bucket_ownership_controls.owner]

  bucket = aws_s3_bucket.bucket.id
  acl    = "private"
}

resource "aws_cloudfront_distribution" "cdn" {
  depends_on = [aws_s3_bucket.bucket] 
  
  origin {
    domain_name = aws_s3_bucket.bucket.bucket_regional_domain_name
    origin_id   = aws_s3_bucket.bucket.id

    s3_origin_config {
      origin_access_identity = aws_cloudfront_origin_access_identity.origin_access_identity.cloudfront_access_identity_path
    }
  }

  enabled             = true
  is_ipv6_enabled     = true
  comment             = "My CloudFront Distribution"
  default_root_object = "index.html"

  default_cache_behavior {
    allowed_methods  = ["GET", "HEAD"]
    cached_methods   = ["GET", "HEAD"]
    target_origin_id = aws_s3_bucket.bucket.id

    forwarded_values {
      query_string = false
      cookies {
        forward = "none"
      }
    }

    viewer_protocol_policy = "redirect-to-https"
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    cloudfront_default_certificate = true
  }
}

resource "aws_cloudfront_origin_access_identity" "origin_access_identity" {
  comment = "Origin Access Identity for my-bucket"
}

# Network Load Balancer
# Target Group
resource "aws_lb_target_group" "asg_target_group" {
  name     = "asg-target-group"
  port     = 80  
  protocol = "TCP"
  vpc_id   = aws_vpc.main.id
}


# Listener Configuration
resource "aws_lb_listener" "listener" {
  load_balancer_arn = aws_lb.network_lb.arn
  port              = 80  
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.asg_target_group.arn
  }
  
}


# Attach Target Group to Auto Scaling Group
resource "aws_autoscaling_attachment" "asg_target_attachment" {
  autoscaling_group_name = aws_autoscaling_group.ec2_autoscaling_group.name
  lb_target_group_arn    = aws_lb_target_group.asg_target_group.arn
}


# Network Load Balancer Security Group
resource "aws_security_group" "nlb_sg" {
  name_prefix = "nlb-sg"
  vpc_id      = aws_vpc.main.id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# Network Load Balancer
resource "aws_lb" "network_lb" {
  name               = "network-lb"
  load_balancer_type = "network"
  subnets            = [aws_subnet.public[0].id]  # Specify the public subnet for the NLB
  security_groups    = [aws_security_group.nlb_sg.id]
}


# Security Group for NLB Ingress
resource "aws_security_group_rule" "nlb_ingress" {
  type              = "ingress"
  from_port         = 80
  to_port           = 80
  protocol          = "tcp"
  cidr_blocks       = ["0.0.0.0/0"]  
  security_group_id = aws_security_group.nlb_sg.id
}