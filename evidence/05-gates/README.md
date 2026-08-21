# C5 — three gates that actually block

Each: branch → insecure change → red PR → fix commit → green → merge.

| Gate | Red PR | Fix | What it does NOT catch |
|---|---|---|---|
| gitleaks | _link_ | _sha_ | Secrets below entropy/rule threshold; credentials that never enter git (state file, chat). |
| trivy config | _link_ | _sha_ | Runtime SG drift; LocalStack ignoring custom SGs. |
| zizmor | _link_ | _sha_ | A malicious commit already at a pinned SHA; compromised maintainer. |
