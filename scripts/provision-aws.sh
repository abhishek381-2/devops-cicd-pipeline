#!/usr/bin/env bash
# =============================================================================
# provision-aws.sh - create everything the pipeline needs on AWS, in one run.
#
# DESIGNED TO RUN IN **AWS CloudShell** (browser terminal, already logged in):
#   https://console.aws.amazon.com  ->  the `>_` icon in the top bar
#   wget -qO- <this-file-raw-url> | bash
#   ...or copy/paste it into CloudShell.
#
# It is safe to run locally too, as long as `aws configure` has been done.
#
# What it creates
#   1. an EC2 key pair  (.pem saved so you can download it)
#   2. a security group  (22 / 80 / 443)
#   3. an Ubuntu 24.04 LTS t3.micro instance, tagged
#   4. an Elastic IP, associated  <-- THIS is what makes the IP permanent
#   5. prints every GitHub secret value you need to paste
#
# It does NOT install Docker or deploy the app - that is `setup-server.sh` on
# the instance, then a `git push` for the pipeline to take over.
#
# Idempotent: re-running reuses an existing key pair / security group /
# Elastic IP that carries the same Name tag instead of creating duplicates.
# =============================================================================
set -Eeuo pipefail

# --------------------------------------------------------------------------- #
# Configuration (override with environment variables)
# --------------------------------------------------------------------------- #
REGION="${REGION:-${AWS_DEFAULT_REGION:-ap-south-1}}"   # Mumbai
PROJECT="${PROJECT:-devops-cicd}"
INSTANCE_TYPE="${INSTANCE_TYPE:-t3.micro}"               # Free Tier eligible
VOLUME_GB="${VOLUME_GB:-20}"
KEY_NAME="${KEY_NAME:-${PROJECT}-deploy}"
SG_NAME="${SG_NAME:-${PROJECT}-sg}"
SSH_CIDR="${SSH_CIDR:-0.0.0.0/0}"                        # see the warning below
PEM_PATH="${PEM_PATH:-$HOME/${KEY_NAME}.pem}"
OUTPUT_FILE="${OUTPUT_FILE:-$HOME/${PROJECT}-secrets.txt}"

log()  { printf '\033[0;36m[provision]\033[0m %s\n' "$*"; }
ok()   { printf '\033[0;32m[provision]\033[0m %s\n' "$*"; }
warn() { printf '\033[0;33m[provision]\033[0m %s\n' "$*"; }
die()  { printf '\033[0;31m[provision][ERROR]\033[0m %s\n' "$*" >&2; exit 1; }

command -v aws >/dev/null 2>&1 || die "The AWS CLI is not installed.
  Easiest fix: open AWS CloudShell (the >_ icon in the AWS console) and run
  this script there - the CLI and your login are already set up."

export AWS_DEFAULT_REGION="${REGION}"

log "Checking your AWS identity ..."
IDENTITY="$(aws sts get-caller-identity --query 'Arn' --output text 2>/dev/null)" \
    || die "Not authenticated. Run 'aws configure' or use AWS CloudShell."
ok "  $IDENTITY"
ok "  Region: ${REGION}"

ACCOUNT_ID="$(aws sts get-caller-identity --query 'Account' --output text)"

# --------------------------------------------------------------------------- #
# 1. Key pair
# --------------------------------------------------------------------------- #
log "1/6 Key pair '${KEY_NAME}' ..."
if aws ec2 describe-key-pairs --key-names "${KEY_NAME}" >/dev/null 2>&1; then
    warn "  It already exists - reusing it."
    if [[ -f "${PEM_PATH}" ]]; then
        ok "  Private key found at ${PEM_PATH}"
    else
        warn "  The .pem is NOT on this machine. AWS never re-issues it."
        warn "  Options: (a) reuse a .pem you already downloaded,"
        warn "           (b) delete the key pair in the console and re-run this script."
        warn "  If your EC2_SSH_PRIVATE_KEY secret already works, you can ignore this."
    fi
else
    aws ec2 create-key-pair \
        --key-name "${KEY_NAME}" \
        --key-type ed25519 \
        --query 'KeyMaterial' --output text >"${PEM_PATH}"
    chmod 600 "${PEM_PATH}"
    ok "  Created. Private key: ${PEM_PATH}"
    ok "  In CloudShell download it: Actions menu -> Download file -> ${PEM_PATH##*/}"
fi

# --------------------------------------------------------------------------- #
# 2. Security group
# --------------------------------------------------------------------------- #
log "2/6 Security group '${SG_NAME}' ..."
VPC_ID="$(aws ec2 describe-vpcs --filters Name=is-default,Values=true \
          --query 'Vpcs[0].VpcId' --output text)"
[[ "${VPC_ID}" == "None" || -z "${VPC_ID}" ]] && \
    VPC_ID="$(aws ec2 describe-vpcs --query 'Vpcs[0].VpcId' --output text)"
ok "  VPC: ${VPC_ID}"

SG_ID="$(aws ec2 describe-security-groups \
          --filters "Name=group-name,Values=${SG_NAME}" "Name=vpc-id,Values=${VPC_ID}" \
          --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null || true)"

if [[ -z "${SG_ID}" || "${SG_ID}" == "None" ]]; then
    SG_ID="$(aws ec2 create-security-group \
        --group-name "${SG_NAME}" \
        --description "devops-cicd-app: SSH + HTTP + HTTPS" \
        --vpc-id "${VPC_ID}" \
        --query 'GroupId' --output text)"
    ok "  Created: ${SG_ID}"

    for rule in "22:${SSH_CIDR}:SSH" "80:0.0.0.0/0:HTTP" "443:0.0.0.0/0:HTTPS"; do
        port="${rule%%:*}"
        rest="${rule#*:}"
        cidr="${rest%%:*}"
        aws ec2 authorize-security-group-ingress --group-id "${SG_ID}" \
            --protocol tcp --port "${port}" --cidr "${cidr}" >/dev/null
        ok "  Opened ${port} (${cidr})"
    done
else
    warn "  It already exists - reusing ${SG_ID}"
fi

# --------------------------------------------------------------------------- #
# 3. Ubuntu 24.04 AMI
# --------------------------------------------------------------------------- #
log "3/6 Looking up the latest Ubuntu 24.04 LTS AMI ..."
AMI_ID="$(aws ssm get-parameter \
    --name /aws/service/canonical/ubuntu/server/24.04/stable/current/amd64/hvm/ebs-gp3/ami-id \
    --query 'Parameter.Value' --output text)"
ok "  ${AMI_ID}"

# --------------------------------------------------------------------------- #
# 4. Launch the instance
# --------------------------------------------------------------------------- #
log "4/6 Launching a ${INSTANCE_TYPE} instance ..."

EXISTING_ID="$(aws ec2 describe-instances \
    --filters "Name=tag:Name,Values=${PROJECT}" \
              "Name=instance-state-name,Values=pending,running,stopping,stopped" \
    --query 'Reservations[0].Instances[0].InstanceId' --output text 2>/dev/null || true)"

if [[ -n "${EXISTING_ID}" && "${EXISTING_ID}" != "None" ]]; then
    INSTANCE_ID="${EXISTING_ID}"
    warn "  Found an existing instance (${INSTANCE_ID}) - reusing it."
else
    INSTANCE_ID="$(aws ec2 run-instances \
        --image-id "${AMI_ID}" \
        --instance-type "${INSTANCE_TYPE}" \
        --key-name "${KEY_NAME}" \
        --security-group-ids "${SG_ID}" \
        --block-device-mappings \
          "DeviceName=/dev/sda1,Ebs={VolumeSize=${VOLUME_GB},VolumeType=gp3,DeleteOnTermination=true}" \
        --tag-specifications \
          "ResourceType=instance,Tags=[{Key=Name,Value=${PROJECT}},{Key=Project,Value=devops-cicd-app}]" \
        --metadata-options "HttpTokens=required,HttpEndpoint=enabled" \
        --query 'Instances[0].InstanceId' --output text)"
    ok "  Launched: ${INSTANCE_ID}"
fi

log "  Waiting for it to be running ..."
aws ec2 wait instance-running --instance-ids "${INSTANCE_ID}"
aws ec2 wait instance-status-ok --instance-ids "${INSTANCE_ID}" || \
    warn "  Status check still pending - it usually settles within a minute."
ok "  Running."

# --------------------------------------------------------------------------- #
# 5. Elastic IP  <-- the "permanent address" bit
# --------------------------------------------------------------------------- #
log "5/6 Elastic IP ..."
EIP_ALLOC_ID="$(aws ec2 describe-addresses \
    --filters "Name=tag:Name,Values=${PROJECT}-eip" \
    --query 'Addresses[0].AllocationId' --output text 2>/dev/null || true)"

if [[ -z "${EIP_ALLOC_ID}" || "${EIP_ALLOC_ID}" == "None" ]]; then
    EIP_ALLOC_ID="$(aws ec2 allocate-address --domain vpc \
        --tag-specifications \
          "ResourceType=elastic-ip,Tags=[{Key=Name,Value=${PROJECT}-eip}]" \
        --query 'AllocationId' --output text)"
    ok "  Allocated: ${EIP_ALLOC_ID}"
else
    warn "  Reusing existing allocation ${EIP_ALLOC_ID}"
fi

CURRENT_ASSOC="$(aws ec2 describe-addresses --allocation-ids "${EIP_ALLOC_ID}" \
    --query 'Addresses[0].InstanceId' --output text)"
if [[ "${CURRENT_ASSOC}" == "${INSTANCE_ID}" ]]; then
    ok "  Already associated with ${INSTANCE_ID}"
else
    aws ec2 associate-address --instance-id "${INSTANCE_ID}" \
        --allocation-id "${EIP_ALLOC_ID}" >/dev/null
    ok "  Associated with ${INSTANCE_ID}"
fi

PUBLIC_IP="$(aws ec2 describe-addresses --allocation-ids "${EIP_ALLOC_ID}" \
    --query 'Addresses[0].PublicIp' --output text)"
ok "  Public IP: ${PUBLIC_IP}  (this does NOT change when you stop/start)"

# --------------------------------------------------------------------------- #
# 6. Summary + the GitHub secrets you must paste
# --------------------------------------------------------------------------- #
# The instance booted seconds ago, so sshd may not be listening yet.
# Retry so the workflow gets a real pinned host key instead of the TOFU fallback.
HOST_KEY=""
log "  Reading the SSH host key (this can take ~30s on a fresh instance) ..."
for _ in $(seq 1 10); do
    HOST_KEY="$(ssh-keyscan -t ed25519 -H "${PUBLIC_IP}" 2>/dev/null | head -1 || true)"
    [[ -n "${HOST_KEY}" ]] && break
    sleep 5
done
if [[ -n "${HOST_KEY}" ]]; then
    ok "  Host key pinned."
else
    warn "  Could not reach SSH yet. Leave EC2_SSH_KNOWN_HOSTS blank -"
    warn "  the workflow then trusts the host key on first use (ssh-keyscan)."
fi

log "6/6 Writing the summary to ${OUTPUT_FILE} ..."
{
    echo "# ====================================================================="
    echo "# devops-cicd-app - AWS deployment values"
    echo "# Generated $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    echo "# Treat this file as a SECRET. Do not commit it."
    echo "# ====================================================================="
    echo ""
    echo "AWS_ACCOUNT   = ${ACCOUNT_ID}"
    echo "INSTANCE_ID   = ${INSTANCE_ID}"
    echo "REGION        = ${REGION}"
    echo "SECURITY_GRP  = ${SG_ID}"
    echo "ELASTIC_IP_ID = ${EIP_ALLOC_ID}"
    echo "PUBLIC_IP     = ${PUBLIC_IP}"
    echo "KEY_FILE      = ${PEM_PATH}"
    echo ""
    echo "# ---- Paste these into GitHub: Settings > Secrets and variables > Actions ----"
    echo "EC2_HOST            = ${PUBLIC_IP}"
    echo "EC2_USER            = deployer"
    echo "APP_DOMAIN          = ${PUBLIC_IP}"
    echo "PRODUCTION_ENV      = production"
    echo "EC2_SSH_KNOWN_HOSTS = ${HOST_KEY}"
    echo ""
    echo "EC2_SSH_PRIVATE_KEY = (the whole contents of ${PEM_PATH}, including the"
    echo "                       BEGIN and END lines)"
    echo ""
    echo "GHCR_USERNAME       = <your GitHub username>"
    echo "GHCR_TOKEN          = <a fine-grained PAT with Packages: Read>"
} >"${OUTPUT_FILE}"
chmod 600 "${OUTPUT_FILE}"

echo
ok "================================================================"
ok " AWS RESOURCES READY"
ok "================================================================"
ok " Instance      : ${INSTANCE_ID}  (${INSTANCE_TYPE}, ${REGION})"
ok " Public IP     : ${PUBLIC_IP}   <- permanent (Elastic IP)"
ok " Key file      : ${PEM_PATH}"
ok " Secrets file  : ${OUTPUT_FILE}"
ok "================================================================"
echo
log "NEXT STEPS"
log "  1. Download the .pem from CloudShell (Actions > Download file)"
log "  2. Copy setup-server.sh to the instance and run it:"
log "       ssh -i ${PEM_PATH} ubuntu@${PUBLIC_IP} 'echo ready'   # wait ~60s first"
log "       scp -i ${PEM_PATH} scripts/setup-server.sh ubuntu@${PUBLIC_IP}:/tmp/"
log "       ssh -i ${PEM_PATH} ubuntu@${PUBLIC_IP} 'sudo bash /tmp/setup-server.sh'"
log "  3. Paste the secrets above into your GitHub repository"
log "  4. git push origin main   -> the pipeline deploys automatically"
echo
warn "COST: t3.micro is Free Tier eligible for 12 months on a NEW AWS account."
warn "      Set a Billing alarm at once: Billing > Budgets > Create budget."
warn "      The Elastic IP is free while attached to a RUNNING instance."
warn "      Stop the instance and you may still be billed for the IPv4 address."
