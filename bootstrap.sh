#!/usr/bin/env bash
# Create or delete the S3 bucket used as a Terraform remote state backend.
# Generic: works for any project. Idempotent.
#
# Usage:
#   ./bootstrap.sh create   --project NAME [--region REGION] [options]
#   ./bootstrap.sh destroy  --project NAME [--region REGION] [options]
#   ./bootstrap.sh help
#
set -Eeuo pipefail

DEFAULT_REGION="us-east-2"
MANAGED_TAG="tfstate-bootstrap"

log()  { echo "[bootstrap] $*"; }
warn() { echo "[bootstrap] WARN: $*" >&2; }
fail() { echo "[bootstrap] ERROR: $*" >&2; exit 1; }

usage() {
  cat <<'EOF'
Usage:
  bootstrap.sh create  [options]     Create and harden the state bucket.
  bootstrap.sh destroy [options]     Empty and delete the state bucket.
  bootstrap.sh help

create options:
  --project NAME            Project name. Default bucket:
                            <project>-tfstate-<account_id>.
  --bucket NAME             Explicit bucket name (instead of --project).
  --region REGION           AWS region (default: $AWS_REGION or us-east-2).
  --profile PROFILE         AWS CLI profile.
  --kms-key ID              Use SSE-KMS with that key (default: SSE-S3/AES256).
  --noncurrent-expiration-days N
                            Expire noncurrent versions after N days (optional).
  --dry-run                 Print the commands without running them.

destroy options:
  --project / --bucket / --region / --profile (same as create)
  --yes                     Do not ask for confirmation (automation).
  --dry-run                 Print the commands without running them.

Examples:
  ./bootstrap.sh create  --project email --region us-east-2
  ./bootstrap.sh create  --bucket my-tfstate-123456789012 --region us-east-2
  ./bootstrap.sh destroy --project email --region us-east-2
  ./bootstrap.sh destroy --bucket my-tfstate-123456789012 --yes
EOF
}

CMD="${1:-}"
[[ $# -gt 0 ]] && shift

PROJECT=""
BUCKET=""
REGION=""
PROFILE=""
KMS_KEY=""
NONCURRENT_DAYS=""
YES=0
DRY_RUN=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project) PROJECT="${2:?missing value for --project}"; shift 2 ;;
    --bucket) BUCKET="${2:?missing value for --bucket}"; shift 2 ;;
    --region) REGION="${2:?missing value for --region}"; shift 2 ;;
    --profile) PROFILE="${2:?missing value for --profile}"; shift 2 ;;
    --kms-key) KMS_KEY="${2:?missing value for --kms-key}"; shift 2 ;;
    --noncurrent-expiration-days) NONCURRENT_DAYS="${2:?missing value}"; shift 2 ;;
    --yes) YES=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) fail "unknown option: $1" ;;
  esac
done

case "$CMD" in
  create|destroy) ;;
  help|-h|--help|"") usage; [[ -z "$CMD" ]] && exit 2 || exit 0 ;;
  *) usage; exit 2 ;;
esac

command -v aws >/dev/null 2>&1 || fail "'aws' not found in PATH."

REGION="${REGION:-${AWS_REGION:-${AWS_DEFAULT_REGION:-$DEFAULT_REGION}}}"

AWS_CLI=(aws)
[[ -n "$PROFILE" ]] && AWS_CLI+=(--profile "$PROFILE")

aws_s3() { "${AWS_CLI[@]}" --region "$REGION" s3api "$@"; }

# run_s3: like running aws_s3, but prints the real aws command in --dry-run.
run_s3() {
  if [[ "$DRY_RUN" -eq 1 ]]; then
    printf '[dry-run] %s --region %s s3api %s\n' "${AWS_CLI[*]}" "$REGION" "$*"
    return 0
  fi
  aws_s3 "$@" >/dev/null
}

ACCOUNT_ID="$("${AWS_CLI[@]}" sts get-caller-identity --query Account --output text 2>/dev/null)" \
  || fail "no valid AWS credentials (check --profile / SSO)."

if [[ -z "$PROJECT" && -z "$BUCKET" ]]; then
  fail "pass --project or --bucket."
fi
[[ -n "$BUCKET" ]] || BUCKET="${PROJECT}-tfstate-${ACCOUNT_ID}"

tls_policy() {
  cat <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "DenyInsecureTransport",
      "Effect": "Deny",
      "Principal": "*",
      "Action": "s3:*",
      "Resource": [
        "arn:aws:s3:::${BUCKET}",
        "arn:aws:s3:::${BUCKET}/*"
      ],
      "Condition": { "Bool": { "aws:SecureTransport": "false" } }
    }
  ]
}
EOF
}

lifecycle_policy() {
  local rules
  rules='{"Rules":[{"ID":"AbortIncompleteMultipartUpload","Status":"Enabled","Filter":{},"AbortIncompleteMultipartUpload":{"DaysAfterInitiation":7}}'
  if [[ -n "$NONCURRENT_DAYS" ]]; then
    rules+=',{"ID":"ExpireNoncurrentVersions","Status":"Enabled","Filter":{},"NoncurrentVersionExpiration":{"NoncurrentDays":'"$NONCURRENT_DAYS"'}}'
  fi
  rules+=']}'
  printf '%s' "$rules"
}

create_bucket() {
  log "Account: ${ACCOUNT_ID} · Region: ${REGION}"
  log "State bucket: ${BUCKET}"

  if aws_s3 head-bucket --bucket "$BUCKET" >/dev/null 2>&1; then
    log "Bucket already exists; enforcing configuration."
  else
    log "Creating bucket..."
    if [[ "$REGION" == "us-east-1" ]]; then
      run_s3 create-bucket --bucket "$BUCKET"
    else
      run_s3 create-bucket --bucket "$BUCKET" \
        --create-bucket-configuration "LocationConstraint=${REGION}"
    fi
  fi

  log "Versioning..."
  run_s3 put-bucket-versioning --bucket "$BUCKET" \
    --versioning-configuration Status=Enabled

  log "Ownership controls (BucketOwnerEnforced)..."
  run_s3 put-bucket-ownership-controls --bucket "$BUCKET" \
    --ownership-controls 'Rules=[{ObjectOwnership=BucketOwnerEnforced}]'

  log "Blocking public access..."
  run_s3 put-public-access-block --bucket "$BUCKET" \
    --public-access-block-configuration \
    "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"

  log "Encryption at rest..."
  if [[ -n "$KMS_KEY" ]]; then
    run_s3 put-bucket-encryption --bucket "$BUCKET" \
      --server-side-encryption-configuration \
      "$(printf '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"aws:kms","KMSMasterKeyID":"%s"},"BucketKeyEnabled":true}]}' "$KMS_KEY")"
  else
    run_s3 put-bucket-encryption --bucket "$BUCKET" \
      --server-side-encryption-configuration \
      '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"},"BucketKeyEnabled":true}]}'
  fi

  log "Bucket policy (require TLS)..."
  run_s3 put-bucket-policy --bucket "$BUCKET" --policy "$(tls_policy)"

  log "Tags..."
  run_s3 put-bucket-tagging --bucket "$BUCKET" \
    --tagging "TagSet=[{Key=Project,Value=${PROJECT:-$BUCKET}},{Key=ManagedBy,Value=${MANAGED_TAG}}]"

  log "Lifecycle (abort incomplete multipart uploads)..."
  run_s3 put-bucket-lifecycle-configuration --bucket "$BUCKET" \
    --lifecycle-configuration "$(lifecycle_policy)"

  cat <<EOF

[bootstrap] Done. Bucket: ${BUCKET}

Save this as backend.hcl next to your Terraform root (adjust "key" if you
have more than one root), then:  terraform init -backend-config=backend.hcl

  bucket       = "${BUCKET}"
  key          = "terraform.tfstate"
  region       = "${REGION}"
  use_lockfile = true

Or hardcode it in the root:

  terraform {
    backend "s3" {
      bucket       = "${BUCKET}"
      key          = "terraform.tfstate"
      region       = "${REGION}"
      use_lockfile = true
    }
  }

Keep this bucket name. To remove it:
  ./bootstrap.sh destroy --bucket ${BUCKET}
EOF
}

# Lists one page (<=1000) of Versions or DeleteMarkers and deletes it. Loops
# until empty; --no-paginate keeps each delete-objects call under the limit.
purge_selector() {
  local selector="$1" desc="$2" items
  while :; do
    items="$(aws_s3 list-object-versions --no-paginate --max-keys 1000 \
      --bucket "$BUCKET" \
      --query "${selector}[].{Key:Key,VersionId:VersionId}" --output json)"
    if [[ -z "$items" || "$items" == "[]" || "$items" == "null" ]]; then
      break
    fi
    log "Deleting batch of ${desc}..."
    aws_s3 delete-objects --bucket "$BUCKET" \
      --delete "$(printf '{"Objects":%s,"Quiet":true}' "$items")" >/dev/null
  done
}

destroy_bucket() {
  if ! aws_s3 head-bucket --bucket "$BUCKET" >/dev/null 2>&1; then
    log "Bucket ${BUCKET} does not exist; nothing to do."
    return 0
  fi

  local loc
  loc="$(aws_s3 get-bucket-location --bucket "$BUCKET" --query LocationConstraint --output text 2>/dev/null || true)"
  [[ -z "$loc" || "$loc" == "None" ]] || REGION="$loc"

  log "Account: ${ACCOUNT_ID} · Region: ${REGION}"
  log "Bucket to DELETE: ${BUCKET}"

  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "[dry-run] would empty (versions + delete markers) and delete the bucket."
    return 0
  fi

  if [[ "$YES" -ne 1 ]]; then
    [[ -t 0 ]] || fail "no TTY; pass --yes to confirm in automation."
    printf 'Type the exact bucket name to confirm deletion: '
    local answer
    read -r answer
    [[ "$answer" == "$BUCKET" ]] || fail "name does not match; aborted."
  fi

  purge_selector "Versions" "versions"
  purge_selector "DeleteMarkers" "delete markers"

  log "Deleting bucket policy (if any)..."
  run_s3 delete-bucket-policy --bucket "$BUCKET" || true

  log "Deleting bucket..."
  run_s3 delete-bucket --bucket "$BUCKET"

  log "Done. Bucket ${BUCKET} deleted."
}

case "$CMD" in
  create) create_bucket ;;
  destroy) destroy_bucket ;;
esac
