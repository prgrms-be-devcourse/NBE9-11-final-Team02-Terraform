# NBE9-11-final-Team02-Terraform

2026 프로그래머스 데브코스 9기 11회차 백엔드 최종 프로젝트 2팀의 AWS 인프라를 코드로 관리하는 Terraform 저장소입니다.

애플리케이션 저장소: [NBE9-11-final-Team02](https://github.com/prgrms-be-devcourse/NBE9-11-final-Team02)

---

## 개요

SportTeam 서비스의 운영 인프라를 **Terraform(IaC)** 으로 프로비저닝합니다.
단일 EC2 인스턴스 위에 Docker Compose로 애플리케이션·DB·메시지 브로커를 운영하며,
인스턴스 접근은 SSH 대신 **SSM Session Manager**를 사용해 인바운드 SSH 포트를 열지 않습니다.

---

## 구성 리소스

```text
VPC (10.0.0.0/16)
 └─ Subnet (10.0.2.0/24, public)
     ├─ Internet Gateway
     └─ Route Table (0.0.0.0/0 → IGW)

Security Group
 ├─ Inbound  80 (HTTP)
 └─ Outbound 전체 허용

IAM Role + Instance Profile
 ├─ AmazonSSMManagedInstanceCore (SSM 접근)
 └─ SSM Parameter Store 읽기 정책

EC2 (t3.medium, Amazon Linux 2023, 30GB)
 └─ user_data: Docker / Docker Compose / nginx·MySQL·Redis·Kafka·App 부트스트랩

Elastic IP → EC2
```

---

## 주요 설계 포인트

- **SSH 미개방**: 보안 그룹에 22번 포트를 열지 않고, SSM Session Manager로 인스턴스에 접근
- **비밀정보 분리**: DB 비밀번호·GHCR 토큰 등은 `secrets.tf`로 분리하고 `.gitignore` 처리하여 저장소에 노출하지 않음
- **AMI 고정**: `ignore_changes = [ami]`로 최신 AMI 갱신에 따른 인스턴스 교체를 방지
- **부트스트랩 자동화**: `user_data`에서 Docker Compose 기반 서비스(nginx, MySQL, Redis, Kafka, App)를 초기 기동

---

## 디렉터리 구조

```text
infra/
├── main.tf                 # VPC/Subnet/SG/IAM/EC2/EIP 및 user_data
├── variables.tf            # prefix, region 등 변수
├── secrets.tf              # 비밀 변수 (gitignore)
├── .terraform.lock.hcl     # 프로바이더 버전 고정
└── terraform.tfstate       # 상태 파일 (gitignore)
```

---

## 사용 방법

```bash
cd infra

terraform init      # 프로바이더 설치
terraform plan      # 변경 사항 미리보기
terraform apply     # 인프라 생성/변경
```

> `secrets.tf`가 저장소에 포함되지 않으므로 별도 구성 필요

---

## 참고

- 리전: `ap-northeast-2` (서울)
- 상태 관리: 로컬 백엔드 (`terraform.tfstate`)
