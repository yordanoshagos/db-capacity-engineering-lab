# Individual remote state (Yordanos). Bucket/table come from bootstrap/tfstate.sh.
# tflocal rewrites the provider, not the backend — without these endpoints
# init talks to real AWS and dies with InvalidClientTokenId.

bucket         = "tfstate-regional-health"
key            = "envs/yordanos/terraform.tfstate"
region         = "us-east-1"
dynamodb_table = "tfstate-lock"
encrypt        = true

use_path_style              = true
skip_credentials_validation = true
skip_metadata_api_check     = true
skip_region_validation      = true
skip_requesting_account_id  = true

endpoints = {
  s3       = "http://localhost:4566"
  dynamodb = "http://localhost:4566"
  sts      = "http://localhost:4566"
  iam      = "http://localhost:4566"
}
