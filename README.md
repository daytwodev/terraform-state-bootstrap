# terraform-state-bootstrap

Create and delete the S3 bucket used as a Terraform remote state backend.
One bucket per project/account. Idempotent and safe.

## Requirements

- AWS CLI v2 with credentials (profile, SSO, etc.).
- Bash.

## Create

```bash
./bootstrap.sh create --project my-project --region us-east-2
# or an explicit bucket name:
./bootstrap.sh create --bucket my-tfstate-123456789012 --region us-east-2
```

Options: `--profile`, `--kms-key` (SSE-KMS instead of SSE-S3),
`--noncurrent-expiration-days N`, `--dry-run`.

Creates the bucket `<project>-tfstate-<account_id>` with:

- versioning enabled,
- `BucketOwnerEnforced` (ACLs disabled),
- public access blocked,
- SSE-S3 encryption, or SSE-KMS with `--kms-key`, with bucket key enabled,
- a bucket policy that requires TLS,
- tags `Project` and `ManagedBy=tfstate-bootstrap`,
- a lifecycle rule that aborts incomplete multipart uploads after 7 days.

Backend for Terraform:

```hcl
terraform {
  backend "s3" {
    bucket       = "<bucket>"
    key          = "<root>/terraform.tfstate"
    region       = "<region>"
    use_lockfile = true
  }
}
```

No DynamoDB needed: `use_lockfile` uses S3 native locking.

`create` also prints a ready-to-use `backend.hcl` with the real bucket name,
so you can run `terraform init -backend-config=backend.hcl` instead of
hardcoding the backend.

## Delete

```bash
./bootstrap.sh destroy --project my-project --region us-east-2
./bootstrap.sh destroy --bucket my-tfstate-123456789012 --yes
```

You must type the exact bucket name to confirm (unless `--yes`). It deletes all
object versions and delete markers, then the bucket. **Irreversible.**

## IAM permissions

`create`: `sts:GetCallerIdentity`, `s3:ListBucket`, `s3:GetBucketLocation`,
`s3:CreateBucket`, `s3:PutBucketVersioning`, `s3:PutBucketOwnershipControls`,
`s3:PutBucketPublicAccessBlock`, `s3:PutBucketEncryption`,
`s3:PutBucketPolicy`, `s3:PutBucketTagging`,
`s3:PutBucketLifecycleConfiguration`.

`destroy`: `sts:GetCallerIdentity`, `s3:ListBucket`, `s3:GetBucketLocation`,
`s3:ListBucketVersions`, `s3:DeleteObjectVersion`, `s3:DeleteBucketPolicy`,
`s3:DeleteBucket`.

## License

Apache-2.0. See [LICENSE](LICENSE).
