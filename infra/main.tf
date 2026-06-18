terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Team = "devcos-team02"
    }
  }
}

# ── VPC ──────────────────────────────────────────────────────────────────────

resource "aws_vpc" "vpc_1" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "${var.prefix}-vpc"
  }
}

# EC2가 위치할 서브넷 (ap-northeast-2b)
resource "aws_subnet" "subnet_2" {
  vpc_id                  = aws_vpc.vpc_1.id
  cidr_block              = "10.0.2.0/24"
  availability_zone       = "${var.region}b"
  map_public_ip_on_launch = true

  tags = {
    Name = "${var.prefix}-subnet-2"
  }
}

# 인터넷 게이트웨이 - VPC에서 외부 인터넷으로 나가는 출입구
resource "aws_internet_gateway" "igw_1" {
  vpc_id = aws_vpc.vpc_1.id

  tags = {
    Name = "${var.prefix}-igw-1"
  }
}

# 라우팅 테이블 - 모든 트래픽(0.0.0.0/0)을 인터넷 게이트웨이로 보냄
resource "aws_route_table" "rt_1" {
  vpc_id = aws_vpc.vpc_1.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw_1.id
  }

  tags = {
    Name = "${var.prefix}-rt-1"
  }
}

# 서브넷을 라우팅 테이블에 연결 - 이 연결이 있어야 서브넷에서 인터넷 통신 가능
resource "aws_route_table_association" "association_2" {
  subnet_id      = aws_subnet.subnet_2.id
  route_table_id = aws_route_table.rt_1.id
}

# ── 보안 그룹 ─────────────────────────────────────────────────────────────────

resource "aws_security_group" "sg_1" {
  name   = "${var.prefix}-sg"
  vpc_id = aws_vpc.vpc_1.id

  # HTTP - Nginx가 80포트로 받아서 8090으로 프록시
  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # 아웃바운드 전체 허용 (SSM, Docker Hub, GHCR 등)
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "all"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.prefix}-sg"
  }
}

# ── IAM (EC2 권한) ────────────────────────────────────────────────────────────

# EC2에 부여할 IAM 역할
resource "aws_iam_role" "ec2_role_1" {
  name = "${var.prefix}-ec2-role-2"

  assume_role_policy = <<EOF
  {
    "Version": "2012-10-17",
    "Statement": [
      {
        "Sid": "",
        "Action": "sts:AssumeRole",
        "Principal": {
            "Service": "ec2.amazonaws.com"
        },
        "Effect": "Allow"
      }
    ]
  }
  EOF
}

# SSM으로 EC2에 접속하기 위한 정책 (SSH key 없이 접속 가능)
resource "aws_iam_role_policy_attachment" "ec2_ssm" {
  role       = aws_iam_role.ec2_role_1.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# SSM Parameter Store에서 /team02/* 경로의 파라미터 읽기 권한
resource "aws_iam_role_policy" "ec2_ssm_parameter_read" {
  name = "${var.prefix}-ssm-parameter-read"
  role = aws_iam_role.ec2_role_1.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["ssm:GetParameter"]
      Resource = "arn:aws:ssm:${var.region}:*:parameter/team02/*"
    }]
  })
}

resource "aws_iam_instance_profile" "instance_profile_1" {
  name = "${var.prefix}-instance-profile-2"
  role = aws_iam_role.ec2_role_1.name
}

# ── EC2 초기화 스크립트 ───────────────────────────────────────────────────────

locals {
  ec2_user_data_base = <<-END_OF_FILE
#!/bin/bash
# 스왑 메모리 4GB 설정 (t3.small 메모리 부족 대비)
sudo dd if=/dev/zero of=/swapfile bs=128M count=32
sudo chmod 600 /swapfile
sudo mkswap /swapfile
sudo swapon /swapfile
sudo sh -c 'echo "/swapfile swap swap defaults 0 0" >> /etc/fstab'

# Docker 설치
yum install docker -y
systemctl enable docker
systemctl start docker

# Nginx 설치 및 설정 (80 → 8090 리버스 프록시)
yum install -y nginx
cat << 'NGINX_EOF' > /etc/nginx/conf.d/sportteam.conf
server {
    listen 80;

    location / {
        proxy_pass http://localhost:8090;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
    }
}
NGINX_EOF
systemctl enable nginx
systemctl start nginx

# Docker 컨테이너들이 통신할 내부 네트워크
docker network create common

# Redis
docker run -d \
  --name=redis_1 \
  --restart unless-stopped \
  --network common \
  -p 6379:6379 \
  -e TZ=Asia/Seoul \
  redis:7.4 --requirepass ${var.password_1}

# MySQL
docker run -d \
  --name mysql_1 \
  --restart unless-stopped \
  -v /dockerProjects/mysql_1/volumes/var/lib/mysql:/var/lib/mysql \
  -v /dockerProjects/mysql_1/volumes/etc/mysql/conf.d:/etc/mysql/conf.d \
  --network common \
  -p 3306:3306 \
  -e MYSQL_ROOT_PASSWORD=${var.password_1} \
  -e TZ=Asia/Seoul \
  mysql:8.4

# MySQL 준비될 때까지 대기
echo "MySQL이 기동될 때까지 대기 중..."
until docker exec mysql_1 mysql -uroot -p${var.password_1} -e "SELECT 1" &> /dev/null; do
  echo "MySQL이 아직 준비되지 않음. 5초 후 재시도..."
  sleep 5
done
echo "MySQL이 준비됨. 초기화 스크립트 실행 중..."

# DB 유저 및 스키마 초기화
docker exec mysql_1 mysql -uroot -p${var.password_1} -e "
CREATE USER 'team02local'@'127.0.0.1' IDENTIFIED WITH caching_sha2_password BY '${var.local_db_password}';
CREATE USER 'team02local'@'172.18.%.%' IDENTIFIED WITH caching_sha2_password BY '${var.local_db_password}';
CREATE USER 'team02'@'%' IDENTIFIED WITH caching_sha2_password BY '${var.password_1}';

CREATE DATABASE team02_prod;

GRANT ALL PRIVILEGES ON team02_prod.* TO 'team02local'@'127.0.0.1';
GRANT ALL PRIVILEGES ON team02_prod.* TO 'team02local'@'172.18.%.%';
GRANT ALL PRIVILEGES ON team02_prod.* TO 'team02'@'%';

FLUSH PRIVILEGES;
"

# GHCR 로그인 (GitHub Container Registry에서 이미지 pull)
echo "${var.github_access_token_1}" | docker login ghcr.io -u ${var.github_access_token_1_owner} --password-stdin

END_OF_FILE
}

# ── EC2 인스턴스 ──────────────────────────────────────────────────────────────

# 최신 Amazon Linux 2023 AMI를 SSM Parameter Store에서 자동으로 가져옴
data "aws_ssm_parameter" "amazon_linux_ami" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

resource "aws_instance" "ec2_1" {
  ami                         = data.aws_ssm_parameter.amazon_linux_ami.value
  instance_type               = "t3.small"
  subnet_id                   = aws_subnet.subnet_2.id
  vpc_security_group_ids      = [aws_security_group.sg_1.id]
  associate_public_ip_address = true
  iam_instance_profile        = aws_iam_instance_profile.instance_profile_1.name

  tags = {
    Name = "${var.prefix}-web"
  }

  root_block_device {
    volume_type = "gp3"
    volume_size = 12
  }

  user_data = <<-EOF
${local.ec2_user_data_base}
EOF
}
