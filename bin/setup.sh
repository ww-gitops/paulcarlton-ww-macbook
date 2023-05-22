#!/usr/bin/env bash

# Utility setting local kubernetes cluster
# Version: 1.0
# Author: Paul Carlton (mailto:paul.carlton@weave.works)

set -euo pipefail

function usage()
{
    echo "usage ${0} [--debug] [--force-bootstrap] " >&2
    echo "This script will initialize vault" >&2
}

function args() {
  bootstrap=0
  arg_list=( "$@" )
  arg_count=${#arg_list[@]}
  arg_index=0
  while (( arg_index < arg_count )); do
    case "${arg_list[${arg_index}]}" in
          "--debug") set -x;;
          "--force-bootstap") bootstrap=1;;
               "-h") usage; exit;;
           "--help") usage; exit;;
               "-?") usage; exit;;
        *) if [ "${arg_list[${arg_index}]:0:2}" == "--" ];then
               echo "invalid argument: ${arg_list[${arg_index}]}" >&2
               usage; exit
           fi;
           break;;
    esac
    (( arg_index+=1 ))
  done
}

args "$@"

SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
pushd $SCRIPT_DIR/.. >/dev/null
source .envrc

git config pull.rebase true  

if [ $bootstrap -eq 0 ]; then
  set +e
  kubectl get ns | grep flux-system
  bootstrap=$?
  set -e
fi
if [ $bootstrap -eq 0 ]; then
  echo "flux-system namespace already. skipping bootstrap"
else
  bootstrap.sh
fi

cat resources/cluster-config.yaml | envsubst > cluster/config/cluster-config.yaml

if [ -f resources/CA.cer ]; then
  echo "Certificate Authority already exists"
else
  ca-cert.sh
fi

kubectl apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: ca-key-pair
  namespace: cert-manager
data:
  tls.crt: $(base64 -i resources/CA.cer)
  tls.key: $(base64 -i resources/CA.key)
EOF

# Wait for vault to start
while ( true ); do
  echo "Waiting for vault to start"
  started=$(kubectl get pod/vault-0 -n vault -o json 2>/dev/null | jq -r '.status.containerStatuses[0].started')
  if [ "$started" == "true" ]; then
    break
  fi
done

# Initialize vault
vault-init.sh
vault-unseal.sh

kubectl apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: vault-token
  namespace: vault
data:
  vault-token: $(jq -r '.root_token' resources/.vault-init.json | base64)
EOF

set +e
vault-secrets-config.sh
set -e

export CLUSTER_IP=$(kubectl get svc -n ingress-nginx ingress-nginx-controller -o jsonpath='{.spec.clusterIP}')
export AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query "Account" --output text)
export AWS_REGION=$(vault kv get -format=json  secrets/aws-creds | jq -r '.data.data."AWS_REGION"')
export namespace=flux-system
cat resources/cluster-config.yaml | envsubst > cluster/config/cluster-config.yaml
export namespace=\$\{nameSpace\}
git add cluster/config/cluster-config.yaml
git add cluster/namespace/cluster-config.yaml
cat resources/cluster-config.yaml | envsubst > cluster/namespace/cluster-config.yaml
if [[ `git status --porcelain` ]]; then
  git commit -m "update cluster config"
  git pull
  git push
fi

secrets.sh --tls-skip --wge-entitlement $PWD/resources/wge-entitlement.yaml --secrets $PWD/resources/github-secrets.sh

# Wait for dex to start
kubectl wait --for=condition=Ready kustomization/dex -n flux-system

set +e
vault-oidc-config.sh
set -e
