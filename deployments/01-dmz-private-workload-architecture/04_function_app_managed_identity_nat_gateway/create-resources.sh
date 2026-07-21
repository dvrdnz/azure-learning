#!/usr/bin/env bash
set -euo pipefail

# Simple helper script with placeholder-based subcommands.
# Edit the variables below or export environment variables before running.

RG="rg-<project>-<environment>-<region>"
LOCATION="<azure-region>"
PROJECT="<project>"
ENVIRONMENT="<environment>"
SUBSCRIPTION="<subscription>"

case "${1:-}" in
  create-pip)
    az network public-ip create \
      --resource-group "$RG" \
      --name "pip-${PROJECT}-nat" \
      --sku Standard \
      --tier Regional \
      --allocation-method Static \
      --zone 1 2 3 \
      --ddos-protection-mode Disabled \
      --location "$LOCATION"
    ;;
  create-nat)
    az network nat gateway create \
      --resource-group "$RG" \
      --name "nat-${PROJECT}" \
      --public-ip-addresses "pip-${PROJECT}-nat" \
      --location "$LOCATION"
    ;;
  create-storage)
    az storage account create \
      --name "st${PROJECT}${ENVIRONMENT}" \
      --resource-group "$RG" \
      --location "$LOCATION" \
      --sku Standard_LRS
    ;;
  create-function)
    az functionapp create \
      --resource-group "$RG" \
      --consumption-plan-location "$LOCATION" \
      --runtime powershell \
      --runtime-version 7.4 \
      --functions-version 4 \
      --name "func-${PROJECT}-${ENVIRONMENT}" \
      --storage-account "st${PROJECT}${ENVIRONMENT}" \
      --assign-identity [system]
    ;;
  create-role)
    if [ -f nat-toggle-role.json ]; then
      az role definition create --role-definition nat-toggle-role.json
    else
      echo "nat-toggle-role.json not found in current directory"
      exit 1
    fi
    ;;
  assign-role)
    echo "Bitte <principal-id> und <subscription> ersetzen und den folgenden Befehl ausführen:" >&2
    echo "az role assignment create --assignee <principal-id> --role 'NAT Gateway Toggle Operator' --scope /subscriptions/<subscription>/resourceGroups/${RG}"
    ;;
  deploy-function)
    az functionapp deployment source config-zip \
      --resource-group "$RG" \
      --name "func-${PROJECT}-${ENVIRONMENT}" \
      --src scripts/function/deploy.zip
    ;;
  *)
    echo "Usage: $0 {create-pip|create-nat|create-storage|create-function|create-role|assign-role|deploy-function}"
    exit 2
    ;;
esac
