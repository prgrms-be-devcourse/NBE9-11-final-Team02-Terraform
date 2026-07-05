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

resource "aws_subnet" "subnet_2" {
  vpc_id                  = aws_vpc.vpc_1.id
  cidr_block              = "10.0.2.0/24"
  availability_zone       = "${var.region}b"
  map_public_ip_on_launch = true

  tags = {
    Name = "${var.prefix}-subnet-2"
  }
}

resource "aws_internet_gateway" "igw_1" {
  vpc_id = aws_vpc.vpc_1.id

  tags = {
    Name = "${var.prefix}-igw-1"
  }
}

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

resource "aws_route_table_association" "association_2" {
  subnet_id      = aws_subnet.subnet_2.id
  route_table_id = aws_route_table.rt_1.id
}

# ── 보안 그룹 ─────────────────────────────────────────────────────────────────

resource "aws_security_group" "sg_1" {
  name   = "${var.prefix}-sg"
  vpc_id = aws_vpc.vpc_1.id

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

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

resource "aws_iam_role_policy_attachment" "ec2_ssm" {
  role       = aws_iam_role.ec2_role_1.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

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
sudo dd if=/dev/zero of=/swapfile bs=128M count=32
sudo chmod 600 /swapfile
sudo mkswap /swapfile
sudo swapon /swapfile
sudo sh -c 'echo "/swapfile swap swap defaults 0 0" >> /etc/fstab'

yum install docker -y
systemctl enable docker
systemctl start docker

curl -SL https://github.com/docker/compose/releases/download/v2.27.0/docker-compose-linux-x86_64 -o /usr/local/bin/docker-compose
chmod +x /usr/local/bin/docker-compose

docker network create common

# nginx 설정 부트스트랩. 실제 운영 설정은 첫 배포 시 CD가 레포의
# nginx/conf.d/sportteam.conf로 덮어쓴다(아래는 CD 동작 전까지의 초기값).
mkdir -p /home/ec2-user/nginx/conf.d
cat << 'NGINX_EOF' > /home/ec2-user/nginx/conf.d/sportteam.conf
server {
    listen 80;

    resolver 127.0.0.11 valid=10s ipv6=off;

    set $backend  app1_1:8090;
    set $frontend frontend_1:3000;

    client_max_body_size 20m;

    location /api/ {
        proxy_pass http://$backend;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }

    location /ws/ {
        proxy_pass http://$backend;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
        proxy_read_timeout 3600s;
    }

    location /swagger-ui/ {
        proxy_pass http://$backend;
        proxy_set_header Host $host;
    }
    location /v3/api-docs {
        proxy_pass http://$backend;
        proxy_set_header Host $host;
    }

    location / {
        proxy_pass http://$frontend;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
NGINX_EOF

mkdir -p /home/ec2-user/app
cat << 'COMPOSE_EOF' > /home/ec2-user/app/docker-compose.yaml
services:
  nginx:
    image: nginx:1.30
    container_name: nginx_1
    restart: unless-stopped
    ports:
      - "80:80"
    volumes:
      - /home/ec2-user/nginx/conf.d:/etc/nginx/conf.d:ro
    networks:
      - common

  mysql:
    image: mysql:8.4
    container_name: mysql_1
    restart: unless-stopped
    environment:
      MYSQL_ROOT_PASSWORD: ${var.password_1}
      MYSQL_DATABASE: team02_prod
      MYSQL_USER: team02
      MYSQL_PASSWORD: ${var.password_1}
      TZ: Asia/Seoul
    ports:
      - "3306:3306"
    volumes:
      - mysql_data:/var/lib/mysql
    networks:
      - common

  redis:
    image: redis:7.4
    container_name: redis_1
    restart: unless-stopped
    command: redis-server --requirepass ${var.password_1}
    environment:
      TZ: Asia/Seoul
    networks:
      - common

  kafka:
    image: apache/kafka:3.7.0
    container_name: kafka_1
    restart: unless-stopped
    environment:
      KAFKA_NODE_ID: 1
      KAFKA_PROCESS_ROLES: broker,controller
      KAFKA_CONTROLLER_QUORUM_VOTERS: 1@kafka_1:9093
      KAFKA_LISTENERS: PLAINTEXT://:9092,CONTROLLER://:9093
      KAFKA_ADVERTISED_LISTENERS: PLAINTEXT://kafka_1:9092
      KAFKA_LISTENER_SECURITY_PROTOCOL_MAP: PLAINTEXT:PLAINTEXT,CONTROLLER:PLAINTEXT
      KAFKA_CONTROLLER_LISTENER_NAMES: CONTROLLER
      KAFKA_INTER_BROKER_LISTENER_NAME: PLAINTEXT
      KAFKA_AUTO_CREATE_TOPICS_ENABLE: "true"
      KAFKA_OFFSETS_TOPIC_REPLICATION_FACTOR: 1
      KAFKA_TRANSACTION_STATE_LOG_REPLICATION_FACTOR: 1
      KAFKA_TRANSACTION_STATE_LOG_MIN_ISR: 1
      KAFKA_GROUP_INITIAL_REBALANCE_DELAY_MS: 0
      TZ: Asia/Seoul
    networks:
      - common

  app1_1:
    image: $${APP_IMAGE:-ghcr.io/prgrms-be-devcourse/nbe9-11-team02:latest}
    container_name: app1_1
    restart: unless-stopped
    networks:
      - common
    environment:
      TZ: Asia/Seoul
      SPRING_CONFIG_IMPORT: optional:file:/app/application-secret.yaml
      SPRING_PROFILES_ACTIVE: prod
      KAFKA_BOOTSTRAP_SERVERS: kafka_1:9092
    volumes:
      - /home/ec2-user/secrets/application-secret.yaml:/app/application-secret.yaml:ro
    mem_limit: 600m
    profiles:
      - prod

  app1_2:
    image: $${APP_IMAGE:-ghcr.io/prgrms-be-devcourse/nbe9-11-team02:latest}
    container_name: app1_2
    restart: unless-stopped
    networks:
      - common
    environment:
      TZ: Asia/Seoul
      SPRING_CONFIG_IMPORT: optional:file:/app/application-secret.yaml
      SPRING_PROFILES_ACTIVE: prod
      KAFKA_BOOTSTRAP_SERVERS: kafka_1:9092
    volumes:
      - /home/ec2-user/secrets/application-secret.yaml:/app/application-secret.yaml:ro
    mem_limit: 600m
    profiles:
      - prod

networks:
  common:
    name: common
    external: true

volumes:
  mysql_data:
COMPOSE_EOF

docker-compose -f /home/ec2-user/app/docker-compose.yaml up -d nginx mysql redis kafka

until docker exec mysql_1 mysql -uroot -p${var.password_1} -e "SELECT 1" &> /dev/null; do
  sleep 5
done

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

echo "${var.github_access_token_1}" | docker login ghcr.io -u ${var.github_access_token_1_owner} --password-stdin

END_OF_FILE
}

# ── EC2 인스턴스 ──────────────────────────────────────────────────────────────

data "aws_ssm_parameter" "amazon_linux_ami" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

resource "aws_instance" "ec2_1" {
  ami                         = data.aws_ssm_parameter.amazon_linux_ami.value
  instance_type               = "t3.medium"
  subnet_id                   = aws_subnet.subnet_2.id
  vpc_security_group_ids      = [aws_security_group.sg_1.id]
  associate_public_ip_address = true
  iam_instance_profile        = aws_iam_instance_profile.instance_profile_1.name

  tags = {
    Name = "${var.prefix}-web"
  }

  root_block_device {
    volume_type = "gp3"
    volume_size = 30
  }

  user_data = <<-EOF
${local.ec2_user_data_base}
EOF

  lifecycle {
    ignore_changes = [ami]
  }
}

resource "aws_eip" "eip_1" {
  instance = aws_instance.ec2_1.id
  domain   = "vpc"

  tags = {
    Name = "${var.prefix}-eip-1"
  }
}
