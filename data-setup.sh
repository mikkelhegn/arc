#!/usr/bin/env bash

## For AKS - after Web Apps has been created - same or different namespace???:
az k8s-extension create -c m0601-01-arc-cluster -g m0601-01-lima-rg --name arc-datacontoller \
    --cluster-type connectedClusters --extension-type microsoft.arcdataservices \
    --auto-upgrade false --scope cluster --release-namespace appservice-ns \
    --config Microsoft.CustomLocation.ServiceAccount=sa-bootstrapper

# Check for installed state

az k8s-extension show -c m0601-01-arc-cluster -g m0601-01-lima-rg --name arc-datacontoller \
    --cluster-type connectedClusters | jq -r .installState

# Get info
export extensionId=$(az k8s-extension show -g m0601-01-lima-rg --name arc-datacontoller --cluster-type connectedClusters -c m0601-01-arc-cluster | jq -r .id)
export hostClusterId=$(az connectedk8s show --ids /subscriptions/c484c80e-0a6f-4470-86de-697ecee16984/resourceGroups/m0601-01-lima-rg/providers/Microsoft.Kubernetes/connectedClusters/m0601-01-arc-cluster | jq -r .id)

## Patch to add extension (update will delete existing)
## Watch for namespace... - do we really want to update this???
az customlocation patch -c $extensionId --host-resource-id $hostClusterId -n m0601-01-location \
    --namespace appservice-ns -g m0601-01-lima-rg

az customlocation show -n m0601-01-location -g m0601-01-lima-rg | jq -r .provisioningState

export AZDATA_USERNAME="arcadmin"
export AZDATA_PASSWORD="P@ssw0rd1234"

az deployment group create -g m0601-01-lima-rg --template-file arcDataController.json \
    --parameters namespace='appservice-ns' \
    connectionMode='direct' \
    location='eastus' \
    resourceGroup='m0601-01-lima-rg' \
    controllerName='myController' \
    administratorLogin=$AZDATA_USERNAME \
    administratorPassword=$AZDATA_PASSWORD \
    customLocation='/subscriptions/c484c80e-0a6f-4470-86de-697ecee16984/resourceGroups/m0601-01-lima-rg/providers/Microsoft.ExtendedLocation/customLocations/m0601-01-location' \
    uspClientId="e569ccfe-82c6-4eb3-b456-fd738d39ea78" \
    uspTenantId="72f988bf-86f1-41af-91ab-2d7cd011db47" \
    uspClientSecret="n.WRu2ZZ.xo7BxV.vsE.cB2SGIu0FFUeVp" \
    uspAuthority="https://login.microsoftonline.com" \
    dockerImageTag="public-preview-apr-2021" \
    storageClass="managed-premium" \
    serviceType="LoadBalancer"

# Install client tools: Azure Data CLI (azdata)
sudo apt-get update && sudo apt-get install gnupg ca-certificates curl wget software-properties-common apt-transport-https lsb-release -y
curl -sL https://packages.microsoft.com/keys/microsoft.asc | gpg --dearmor | sudo tee /etc/apt/trusted.gpg.d/microsoft.asc.gpg > /dev/null
sudo add-apt-repository "$(wget -qO- https://packages.microsoft.com/config/ubuntu/20.04/prod.list)"
sudo apt-get update && sudo apt-get install -y azdata-cli

# Create Azure Arc data controller
export AZDATA_USERNAME="arcadmin"
export AZDATA_PASSWORD="P@ssw0rd1234"
export rg=arc-data
export location=westeurope
export ns=arc-data

azdata arc dc create --profile-name azure-arc-aks-default-storage \
    --namespace $ns --name arc-data-controller \
    --subscription c484c80e-0a6f-4470-86de-697ecee16984 \
    --resource-group $rg \
    --location $location \
    --connectivity-mode indirect

# ----------- Above is infra setup, below is workload setup --------------------- #

# Create DB with ARM
az deployment group create -g rg-arc-arc --template-file ./deploy/infra/webapi/arcDataController.json \
    --parameters subscription='c484c80e-0a6f-4470-86de-697ecee16984' \
    resourceGroup=m0520-02-lima-rg \
    customLocation=m0520-02-location \
    location=westeurope \
    namespace=arc-data \
    name=arm-postgres

# Crate Postgres server
azdata arc postgres server create -n postgres01 --workers 1

# Get endpoints
azdata arc postgres endpoint list -n postgres01