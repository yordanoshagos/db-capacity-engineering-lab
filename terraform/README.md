# Individual Terraform root (Yordanos)

Composes `modules/data` and `modules/service` from
[akezasaloi/regional-health-platform](https://github.com/akezasaloi/regional-health-platform)
at a **pinned commit**. No copied resource blocks.

There is **no** `aws_db_instance` (Hobby RDS is 501; MySQL is Aiven) and **no**
`aws_lb` (Hobby ELBv2 is 501; `app_url` is EC2 `public_ip:port`).

```bash
export LOCALSTACK_AUTH_TOKEN=...
export AIVEN_HOST=... AIVEN_PORT=... AIVEN_USER=avnadmin
export AIVEN_PASSWORD=... AIVEN_DB=capacity_lab
export AIVEN_CA_PATH=./secrets/aiven-ca.pem
# never commit those

make up          # TF_DIR=./terraform
make verify
make down
```

Pinned to `d56f94d742cb4238a19a707f416a945423b74ae2` (group `main`). If group
main moves, bump the `?ref=` SHA on both `module` sources in `main.tf` and the
`@sha` in `.github/workflows/ci.yml`.
