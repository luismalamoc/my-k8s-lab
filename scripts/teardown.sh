#!/usr/bin/env bash
# Teardown completo del lab EKS:
#   1) Borra recursos de Kubernetes que crean infra en AWS (Services LB, Ingresses)
#   2) Espera a que AWS termine de borrar los LBs
#   3) Recovery: limpia LBs y Security Groups huérfanos en la VPC
#   4) terraform destroy en orden inverso: 30-app-iam -> 20-eks -> 10-network
#   5) (opcional) Borra el repo ECR hello-api creado a mano fuera de terraform
#
# Uso:
#   AWS_PROFILE=personal AWS_REGION=us-east-1 ./scripts/teardown.sh
#   ./scripts/teardown.sh --dry-run         # solo muestra qué haría
#   ./scripts/teardown.sh --skip-k8s        # si ya no tenés acceso al cluster
#   ./scripts/teardown.sh --only-recovery   # solo limpia LBs/SGs huérfanos
#   ./scripts/teardown.sh --purge-ecr       # también borra el repo ECR hello-api
#
# Por defecto el ECR NO se borra (sus imágenes te ahorran rebuild en el próximo apply).
# El stack 00-bootstrap (S3) NO se borra (cuesta centavos y guarda el state).
# Requiere: aws cli, terraform, kubectl, helm, jq

set -euo pipefail

# ---------- args ----------
DRY_RUN=0
SKIP_K8S=0
ONLY_RECOVERY=0
PURGE_ECR=0
for arg in "$@"; do
  case "$arg" in
    --dry-run)        DRY_RUN=1 ;;
    --skip-k8s)       SKIP_K8S=1 ;;
    --only-recovery)  ONLY_RECOVERY=1 ;;
    --purge-ecr)      PURGE_ECR=1 ;;
    -h|--help)
      sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "Argumento desconocido: $arg" >&2; exit 2 ;;
  esac
done

# ---------- config ----------
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NETWORK_DIR="$REPO_ROOT/infra/aws/10-network"
EKS_DIR="$REPO_ROOT/infra/aws/20-eks"
APP_IAM_DIR="$REPO_ROOT/infra/aws/30-app-iam"
AWS_REGION="${AWS_REGION:-us-east-1}"
export AWS_REGION

# ---------- helpers ----------
c_red()   { printf '\033[31m%s\033[0m\n' "$*"; }
c_green() { printf '\033[32m%s\033[0m\n' "$*"; }
c_blue()  { printf '\033[34m%s\033[0m\n' "$*"; }
c_yellow(){ printf '\033[33m%s\033[0m\n' "$*"; }

step() { echo; c_blue "==> $*"; }
warn() { c_yellow "WARN: $*"; }
die()  { c_red "ERROR: $*"; exit 1; }

run() {
  if [ "$DRY_RUN" = "1" ]; then
    c_yellow "[dry-run] $*"
  else
    eval "$@"
  fi
}

require() { command -v "$1" >/dev/null 2>&1 || die "falta comando: $1"; }

# ---------- preflight ----------
require aws
require terraform
require jq
[ "$SKIP_K8S" = "1" ] || { require kubectl; require helm; }

aws sts get-caller-identity >/dev/null || die "AWS no autenticado (revisá AWS_PROFILE / SSO)"
ACCOUNT="$(aws sts get-caller-identity --query Account --output text)"
c_green "AWS profile=${AWS_PROFILE:-<default>} account=$ACCOUNT region=$AWS_REGION"

# Resolver VPC ID desde el state de 10-network (fallback: tag Name=lab-vpc).
# Solo aceptamos valores que empiecen con "vpc-" para evitar warnings de terraform.
VPC_ID=""
if [ -d "$NETWORK_DIR/.terraform" ]; then
  CANDIDATE="$(terraform -chdir="$NETWORK_DIR" output -raw vpc_id 2>/dev/null || true)"
  [[ "$CANDIDATE" =~ ^vpc-[a-f0-9]+$ ]] && VPC_ID="$CANDIDATE"
fi
if [ -z "$VPC_ID" ]; then
  CANDIDATE="$(aws ec2 describe-vpcs \
    --filters Name=tag:Name,Values=lab-vpc \
    --query 'Vpcs[0].VpcId' --output text 2>/dev/null || true)"
  [[ "$CANDIDATE" =~ ^vpc-[a-f0-9]+$ ]] && VPC_ID="$CANDIDATE"
fi
if [ -n "$VPC_ID" ]; then
  c_green "VPC del lab: $VPC_ID"
else
  warn "No encontré la VPC del lab (¿ya destruida?). Solo voy a limpiar K8s + correr destroys."
fi

# ===========================================================================
# 1) Limpieza de Kubernetes (libera LBs/EBS administrados por el cluster)
# ===========================================================================
if [ "$SKIP_K8S" = "0" ] && [ "$ONLY_RECOVERY" = "0" ]; then
  step "1) Borrando recursos de Kubernetes con efectos en AWS"

  if ! kubectl cluster-info >/dev/null 2>&1; then
    warn "kubectl no puede contactar al cluster (kubeconfig?). Salteando paso 1."
    warn "Si el cluster aún existe, abortá y arreglá el kubeconfig:"
    warn "  aws eks update-kubeconfig --name <cluster> --region $AWS_REGION"
  else
    run "helm uninstall hello-api -n hello 2>/dev/null || true"
    run "kubectl delete svc -A --field-selector spec.type=LoadBalancer --ignore-not-found --timeout=120s || true"
    run "kubectl delete ingress -A --all --ignore-not-found --timeout=120s || true"
    run "kubectl delete ns hello --ignore-not-found --timeout=120s || true"

    step "Esperando que AWS termine de borrar los LBs creados por el cluster (hasta 3 min)..."
    if [ "$DRY_RUN" = "0" ] && [ -n "$VPC_ID" ]; then
      for i in $(seq 1 18); do
        CLB=$(aws elb describe-load-balancers --region "$AWS_REGION" \
              --query "length(LoadBalancerDescriptions[?VPCId=='$VPC_ID'])" --output text 2>/dev/null || echo 0)
        ALB=$(aws elbv2 describe-load-balancers --region "$AWS_REGION" \
              --query "length(LoadBalancers[?VpcId=='$VPC_ID'])" --output text 2>/dev/null || echo 0)
        echo "  [$i/18] LBs en la VPC -> classic=$CLB v2=$ALB"
        if [ "$CLB" = "0" ] && [ "$ALB" = "0" ]; then break; fi
        sleep 10
      done
    fi
  fi
fi

# ===========================================================================
# 2) Recovery: borrar LBs huérfanos en la VPC (si quedaron)
# ===========================================================================
if [ -n "$VPC_ID" ]; then
  step "2) Buscando LBs huérfanos en $VPC_ID"

  ORPHAN_CLB=$(aws elb describe-load-balancers --region "$AWS_REGION" \
    --query "LoadBalancerDescriptions[?VPCId=='$VPC_ID'].LoadBalancerName" --output text 2>/dev/null || true)
  ORPHAN_ALB=$(aws elbv2 describe-load-balancers --region "$AWS_REGION" \
    --query "LoadBalancers[?VpcId=='$VPC_ID'].LoadBalancerArn" --output text 2>/dev/null || true)

  if [ -n "$ORPHAN_CLB" ]; then
    warn "Classic ELBs huérfanos: $ORPHAN_CLB"
    for name in $ORPHAN_CLB; do
      run "aws elb delete-load-balancer --region $AWS_REGION --load-balancer-name $name"
    done
  fi
  if [ -n "$ORPHAN_ALB" ]; then
    warn "ALB/NLB huérfanos: $ORPHAN_ALB"
    for arn in $ORPHAN_ALB; do
      run "aws elbv2 delete-load-balancer --region $AWS_REGION --load-balancer-arn $arn"
    done
  fi

  step "Esperando que las ENIs de los LBs desaparezcan (hasta 2 min)"
  if [ "$DRY_RUN" = "0" ]; then
    for i in $(seq 1 12); do
      N=$(aws ec2 describe-network-interfaces \
            --filters Name=vpc-id,Values="$VPC_ID" \
            --query 'length(NetworkInterfaces)' --output text 2>/dev/null || echo 0)
      echo "  [$i/12] ENIs restantes en la VPC: $N"
      if [ "$N" = "0" ]; then break; fi
      sleep 10
    done
    if [ "$N" != "0" ]; then
      warn "Aún hay $N ENIs en la VPC. Detalle:"
      aws ec2 describe-network-interfaces --filters Name=vpc-id,Values="$VPC_ID" \
        --query 'NetworkInterfaces[].[NetworkInterfaceId,Description,Status,RequesterId]' --output table || true
      die "Resolvé las ENIs restantes a mano antes de seguir (ver ROADMAP §7.6.B)."
    fi
  fi

  # Security Groups huérfanos creados por kube-controller-manager (k8s-elb-*).
  # AWS NO los borra al borrar el ELB; quedan dentro de la VPC y bloquean el
  # destroy del aws_vpc con DependencyViolation silencioso (cuelga indefinido).
  step "Buscando Security Groups huérfanos (k8s-*) en la VPC"
  ORPHAN_SGS=$(aws ec2 describe-security-groups \
    --filters Name=vpc-id,Values="$VPC_ID" "Name=group-name,Values=k8s-*" \
    --query 'SecurityGroups[].GroupId' --output text 2>/dev/null || true)
  if [ -n "$ORPHAN_SGS" ]; then
    warn "SGs huérfanos detectados: $ORPHAN_SGS"
    for sg in $ORPHAN_SGS; do
      run "aws ec2 delete-security-group --region $AWS_REGION --group-id $sg || warn 'No se pudo borrar $sg (¿aún en uso?)'"
    done
  else
    echo "  (ninguno)"
  fi
fi

[ "$ONLY_RECOVERY" = "1" ] && { c_green "Recovery completo. Saliendo (--only-recovery)."; exit 0; }

# ===========================================================================
# 3) Terraform destroy en orden inverso
# ===========================================================================
destroy_stack() {
  local dir="$1" label="$2"
  if [ ! -d "$dir" ]; then warn "no existe $dir, skip"; return 0; fi
  step "3.$label) terraform destroy en $dir"
  if [ ! -d "$dir/.terraform" ]; then
    run "terraform -chdir='$dir' init -backend-config=backend.hcl -reconfigure"
  fi
  run "terraform -chdir='$dir' destroy -auto-approve"
}

destroy_stack "$APP_IAM_DIR" "a 30-app-iam"
destroy_stack "$EKS_DIR"     "b 20-eks (~10 min)"
destroy_stack "$NETWORK_DIR" "c 10-network"

# ===========================================================================
# 4) ECR: repo creado a mano en Fase 6.2, no está en terraform
# ===========================================================================
ECR_REPO="hello-api"
if [ "$PURGE_ECR" = "1" ]; then
  step "4) Borrando repo ECR '$ECR_REPO' (--purge-ecr)"
  if aws ecr describe-repositories --region "$AWS_REGION" --repository-names "$ECR_REPO" >/dev/null 2>&1; then
    run "aws ecr delete-repository --region $AWS_REGION --repository-name $ECR_REPO --force"
  else
    echo "  ($ECR_REPO no existe, nada que hacer)"
  fi
else
  step "4) ECR conservado"
  if aws ecr describe-repositories --region "$AWS_REGION" --repository-names "$ECR_REPO" >/dev/null 2>&1; then
    URI=$(aws ecr describe-repositories --region "$AWS_REGION" --repository-names "$ECR_REPO" \
            --query 'repositories[0].repositoryUri' --output text)
    c_yellow "  Repo '$ECR_REPO' aún existe ($URI)."
    c_yellow "  Para borrarlo y sus imágenes: rerun con --purge-ecr  (o: aws ecr delete-repository --repository-name $ECR_REPO --force)"
  fi
fi

step "Listo."
c_green "Teardown completo. Bootstrap (00-bootstrap) intacto a propósito (S3 cuesta centavos)."
c_green "Si querés borrarlo también: cd infra/aws/00-bootstrap && terraform destroy"
