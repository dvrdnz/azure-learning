#!/usr/bin/env bash
set -euo pipefail

# Helper script (placeholders) for actions described in the docs.

RG="rg-<project>-<environment>-<region>"
LOCATION="<azure-region>"
PROJECT="<project>"
ENVIRONMENT="<environment>"
SUBSCRIPTION="<subscription>"

case "${1:-}" in
  delete-old-nat)
    az network nat gateway delete --resource-group "$RG" --name "nat-${PROJECT}"
    az network public-ip delete --resource-group "$RG" --name "pip-${PROJECT}-nat"
    ;;
  update-role)
    if [ -f nat-toggle-role.json ]; then
      az role definition update --role-definition nat-toggle-role.json
    else
      echo "nat-toggle-role.json fehlt" >&2
      exit 1
    fi
    ;;
  set-app-settings)
    az functionapp config appsettings set \
      --name func-${PROJECT}-${ENVIRONMENT} \
      --resource-group ${RG} \
      --settings \
        TOGGLEWEBINTERNET_RESOURCE_GROUP=${RG} \
        TOGGLEWEBINTERNET_VNET_NAME=vnet-${PROJECT} \
        TOGGLEWEBINTERNET_SUBNET_NAME=snet-web \
        TOGGLEWEBINTERNET_NAT_GATEWAY_NAME=nat-${PROJECT} \
        TOGGLEWEBINTERNET_PUBLIC_IP_NAME=pip-${PROJECT}-nat \
        TOGGLEWEBINTERNET_LOCATION=${LOCATION}
    ;;
  *)
    echo "Usage: $0 {delete-old-nat|update-role|set-app-settings}"
    exit 2
    ;;
esac
