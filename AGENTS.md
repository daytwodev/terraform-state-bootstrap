# AGENTS.md

Guidance for AI coding agents working in this repository. See the
[README](README.md) for usage.

## Project

`terraform-state-bootstrap` is a single Bash script that creates (and deletes)
the S3 bucket used as a Terraform remote state backend. One bucket per
project/account.

## Layout and commands

- `bootstrap.sh` — `create` | `destroy` | `help`.
- `.github/workflows/ci.yml` — runs `bash -n`, `shellcheck`, and
  `./bootstrap.sh help`.

```bash
bash -n bootstrap.sh
shellcheck bootstrap.sh
./bootstrap.sh help
./bootstrap.sh create --project demo --region us-east-2 --dry-run
```

## Rules

- English everywhere; keep it short and direct.
- No dependencies beyond Bash and the AWS CLI.
- `destroy` must require typing the exact bucket name (unless `--yes`) and must
  purge **all** object versions and delete markers before deleting the bucket.
- Never print or log credentials; call the AWS CLI as-is.
- Keep `--dry-run` printing the real, copy-pasteable `aws` commands.

## Status

Stable utility, used to create/delete a central Terraform state bucket. Keep it
generic: no account-specific values (bucket names, account IDs) belong in the
repo.

