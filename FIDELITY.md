# FIDELITY.md — where the emulator lied (individual)

Verified against this rehost, not copied from the group doc alone.

## RDS `aws_db_instance` is unlicensed on LocalStack Hobby (501)

- **What LocalStack did:** apply returned HTTP 501. Terraform accepted the resource in plan and refused to create it.
- **How I detected it:** group `tflocal apply` failed on Saloi's original data module; CI logs showed 501. The lab moved MySQL to Aiven; Secrets Manager still holds `engine, username, password, host, port, dbname`.
- **What I'd verify on real AWS:** `CreateDBInstance` succeeds and `StorageEncrypted` is actually true.

## ELBv2 / ALB is unlicensed on LocalStack Hobby (501)

- **What LocalStack did:** `aws_lb` apply returned InternalFailure / 501.
- **How I detected it:** Berissa's service module failed until PR #6 dropped the ALB. `app_url` is `http://ec2_public_ip:port`.
- **What I'd verify on real AWS:** an ALB `/readyz` health check actually stops traffic to a 503 instance.

## Docker-backed EC2 AMIs never register on Hobby

- **What LocalStack did:** with `EC2_VM_MANAGER=docker` and docker.sock mounted, `describe-images` listed zero docker-backed AMIs. EC2 stayed in mock mode; user-data never ran.
- **How I detected it:** CI in PR #9 printed `docker-backed AMI count=0` for 15 tries; apply only worked after mock AMI + `docker run` on the runner (`APP_URL=http://127.0.0.1:3000`).
- **What I'd verify on real AWS:** the AMI id is a real AMI, user-data executes, and `/readyz` is served from the instance.

## Terraform backend talks to real AWS unless endpoints are set

- **What LocalStack did:** `tflocal` rewrites the *provider*, not the S3 backend. `init` died with `InvalidClientTokenId` against real STS using `test` keys.
- **How I detected it:** CI init failed until `backend.hcl` set `endpoints` to `http://localhost:4566` plus `skip_*` and `use_path_style`.
- **What I'd verify on real AWS:** omit those skip flags; the bucket is versioned, encrypted, and not public.

## Declared instance sizes are IaC only

- **What LocalStack did:** `t3.small` / Aiven class are not enforced. The Codespace is the real hardware.
- **How I detected it:** 2000 k6 VUs + MySQL + LocalStack on 2 vCPU skewed p95. Assignment table: 4 vCPU / 16 GB.
- **What I'd verify on real AWS:** CloudWatch CPU/memory on the instance class you declared.
