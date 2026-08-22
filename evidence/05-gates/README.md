# C5 — three gates that actually block

Each: branch → insecure change → red PR → fix commit → green → merge.

| Gate | Red PR | Fix | What it does NOT catch |
|---|---|---|---|
| gitleaks | [#2](https://github.com/yordanoshagos/db-capacity-engineering-lab/pull/2) (leak still in history) | [#3](https://github.com/yordanoshagos/db-capacity-engineering-lab/pull/3) allowlist `6fbfe1c` | Secrets below entropy/rule threshold; credentials that never enter git (state file, chat). History needs an allowlist or rewrite — deleting the file is not enough. |
| trivy config | [#4](https://github.com/yordanoshagos/db-capacity-engineering-lab/pull/4) AWS-0107 HIGH | _pending — remove `c5-open-sg.tf`_ | Runtime SG drift; LocalStack ignoring custom SGs. |
| zizmor | _link_ | _sha_ | A malicious commit already at a pinned SHA; compromised maintainer. |

## Trivy red (PR #4)

`trivy-config` failed in 28s on [run 32538852837](https://github.com/yordanoshagos/db-capacity-engineering-lab/actions/runs/32538852837). Finding: **AWS-0107** — SG ingress `0.0.0.0/0` on port 22 in `terraform/c5-open-sg.tf`. gitleaks and zizmor stayed green; image build was skipped because config failed.

- `pr-4-trivy-config-red.png` — PR checks: trivy-config failing
- `pr-4-trivy-job.png` — Actions job list (`trivy config .` on `terraform/`)
- `pr-4-trivy-aws-0107.png` — AWS-0107 snippet at `cidr_blocks = ["0.0.0.0/0"]`
