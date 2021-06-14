#!/bin/bash

GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m' # No Color

## Variables

## General stuff
## Checking for prefix for naming
prefix=$1
## location is used for the AKS cluster and the ARC cluster resource
location=$2
## The name of the resource group into which your resources will be provisioned
groupName="${prefix}-lima-rg"
## The subscription ID into which your resources will be provisioned
subscriptionId=$(az account show --query id -o tsv)

## AKS Stuff
## Only needed if using AKS; the name of the resource group in which the AKS cluster resides
aksClusterGroupName="${prefix}-aks-cluster-rg"
aksClusterName="${prefix}-aks-cluster"
## Static IP Name for the cluster
staticIpName="${prefix}-ip"

## Arc stuff
## Log Analytics workspace name
workspaceName="${prefix}-workspace"
## The desired name of your Arc connected cluster resource
clusterName="${prefix}-arc-cluster"
## The desired name of the extensions to be installed in the connected cluster and the namespace to use
extensionNamespace="arc-services"
extensionNameAppSvc="${prefix}-appsvc-ext"
extensionNameDataSvc="${prefix}-datasvc-ext"
## The desired name of your custom location
customLocationName="${prefix}-location"

## AppSvc stuff
## The desired name of your Kubernetes environment
kubeEnvironmentName="${prefix}-kube"

## DataSvc stuff
## Datacontroller name
dataControllerName="${prefix}-data-ctr"
## Data controller login and password
azdata_username=$3
azdata_password=$4
## Data controller uploads credentials
spClientId=$5
spTenantId=$6
spSecret=$7

# Step 0 - Pre-reqs and setup
if
    [[ $prefix == "" ]]
then
    printf "${RED}You need to provide a prefix and location for your resources './lima-setup.sh {prefix} {location} {azdata_username} {azdata_password} {spClientId} {spTenantId} {spSecret}'. The prefix is used to name resoures. All resources created by this script also have the prefix as a tag. ${NC}\n"
    exit 1
fi

printf "${GREEN}Deploying ARC AppSvc and Data Svc to ${location} ${NC}\n"

printf "${GREEN}Log in to Azure ${NC}\n"
az login --use-device-code -o none

## Check installed CLI extensions
printf "${GREEN}Installing Azure-CLI Extensions ${NC}\n"
az extension add --upgrade --yes -n connectedk8s
az extension add --upgrade --yes -n customlocation
az extension add --upgrade --yes -n k8s-extension
az extension add --yes --source "https://aka.ms/appsvc/appservice_kube-latest-py2.py3-none-any.whl"

az version

# Section 1 - Creating AKS Cluster

printf "${GREEN}Creating AKS cluster resource group: ${aksClusterGroupName} in ${location} ${NC}\n"
az group create -n $aksClusterGroupName -l $location --tags prefix=$prefix

printf "${GREEN}Checking if AKS cluster: ${aksClusterName} already exists...${NC}\n"

if
    [[ $(az aks show -g $aksClusterGroupName -n $aksClusterName | jq -r .name) == "${aksClusterName}" ]]
then
    echo "Cluster already exists"
else
    printf "${GREEN}Creating AKS cluster: ${aksClusterName} in ${location} ${NC}\n"
    az aks create -g $aksClusterGroupName -n $aksClusterName -l $location --enable-aad --enable-azure-rbac --generate-ssh-keys --tags prefix=$prefix --enable-addons monitoring
fi

printf "${GREEN}Getting credentials ${NC}\n"
az aks get-credentials -g $aksClusterGroupName -n $aksClusterName --admin
kubectl get ns

printf "${GREEN}Creating static IP for the cluster ${NC}\n"
infra_rg=$(az aks show -g $aksClusterGroupName -n $aksClusterName -o tsv --query nodeResourceGroup)

if
    [[ $(az network public-ip show -g $infra_rg -n $staticIpName | jq -r .name) == "${staticIpName}" ]]
then
    echo "Static IP already exists"
else
    az network public-ip create -g $infra_rg -n $staticIpName --sku STANDARD
fi

staticIp=$(az network public-ip show -g $infra_rg -n $staticIpName | jq -r .ipAddress)
printf "${GREEN}Ip address: ${staticIp} ${NC}\n"

# Section 2 - Creating ARC resource

## Resource Group
printf "${GREEN}Connecting cluster to ARC in RG: ${groupName} ${NC}\n"
printf "${GREEN}Creating resource group for ARC resource: ${groupName} in ${location} ${NC}\n"
az group create -n $groupName -l ${location} --tags prefix=$prefix

## Log Analytics workspace
printf "${GREEN}Creating a Log Analytics Workspace for the cluster ${NC}\n"

if
    [[ $(az monitor log-analytics workspace show -g $groupName -n $workspaceName | jq -r .name) == "${workspaceName}" ]]
then
    echo "Workspace already exists"
else
    az monitor log-analytics workspace create -g $groupName -n $workspaceName -l ${location}
fi

logAnalyticsWorkspaceId=$(az monitor log-analytics workspace show --resource-group $groupName --workspace-name $workspaceName -o tsv --query "customerId")
logAnalyticsWorkspaceIdEnc=$(printf %s $logAnalyticsWorkspaceId | base64)
logAnalyticsKey=$(az monitor log-analytics workspace get-shared-keys --resource-group $groupName --workspace-name $workspaceName -o tsv --query "secondarySharedKey")
logAnalyticsKeyEncWithSpace=$(printf %s $logAnalyticsKey | base64)
logAnalyticsKeyEnc=$(echo -n "${logAnalyticsKeyEncWithSpace//[[:space:]]/}")

## Installing ARC agent

printf "${GREEN}Installing ARC agent${NC}\n"

if
    [[ $(az connectedk8s show -g $groupName -n $clusterName | jq -r .name) == ${clusterName} ]]
then
    echo "Cluster already connected"
else

    az connectedk8s connect -g $groupName -n $clusterName --tags prefix=$prefix
    
    ### Looping until cluster is connected
    while true
    do
        printf "${GREEN}\nChecking connectivity... ${NC}\n" 
        sleep 10
        connectivityStatus=$(az connectedk8s show -n $clusterName -g $groupName | jq -r .connectivityStatus)
        printf "${GREEN}connectivityStatus: ${connectivityStatus} ${NC}\n"
        if
            [[ $connectivityStatus == "Failed" ]]
        then
            exit
        elif
            [[ $connectivityStatus == "Connected" ]]
        then
            break
        fi
    done
fi

connectedClusterId=$(az connectedk8s show -n $clusterName -g $groupName --query id -o tsv)

printf "${GREEN}Let's grab the resources in the cluster: ${NC}\n"
kubectl get pods -n azure-arc

# Step 3 - App Service and Data Service setup

## App Service Extension installation
printf "${GREEN}Installing the App Service extension on your cluster ${NC}\n"

if
    [[ $(az k8s-extension show --cluster-type connectedClusters -c $clusterName -g $groupName --name $extensionNameAppSvc | jq -r .installState) == "Installed" ]]
then
    echo "Extension already installed"
else
    az k8s-extension create -g $groupName --name $extensionNameAppSvc \
        --cluster-type connectedClusters -c $clusterName \
        --extension-type 'Microsoft.Web.Appservice' \
        --auto-upgrade-minor-version true \
        --scope cluster \
        --release-namespace $extensionNamespace \
        --configuration-settings "Microsoft.CustomLocation.ServiceAccount=default" \
        --configuration-settings "appsNamespace=${extensionNamespace}" \
        --configuration-settings "clusterName=${kubeEnvironmentName}" \
        --configuration-settings "loadBalancerIp=${staticIp}" \
        --configuration-settings "keda.enabled=true" \
        --configuration-settings "buildService.storageClassName=default" \
        --configuration-settings "buildService.storageAccessMode=ReadWriteOnce" \
        --configuration-settings "envoy.annotations.service.beta.kubernetes.io/azure-load-balancer-resource-group=${aksClusterGroupName}" \
        --configuration-settings "logProcessor.appLogs.destination=log-analytics" \
        --configuration-settings "logProcessor.appLogs.logAnalyticsConfig.customerId=${logAnalyticsWorkspaceIdEnc}" \
        --configuration-settings "logProcessor.appLogs.logAnalyticsConfig.sharedKey=${logAnalyticsKeyEnc}" \
        --configuration-settings "customConfigMap=${extensionNamespace}/kube-environment-config"

    ### Looping until extention is installed
    while true
    do
        printf "${GREEN}\nChecking state of extension... ${NC}\n" 
        sleep 10
        installState=$(az k8s-extension show --cluster-type connectedClusters -c $clusterName -g $groupName --name $extensionNameAppSvc | jq -r .installState)
        printf "${GREEN}installState: ${installState} ${NC}\n"
        if
            [[ $installState == "Failed" ]]
        then
            exit
        elif
            [[ $installState == "Installed" ]]
        then
            break
        fi
    done
fi

extensionIdAppSvc=$(az k8s-extension show --cluster-type connectedClusters -c $clusterName -g $groupName --name $extensionNameAppSvc --query id -o tsv)

## Data Services extension installation
printf "${GREEN}Installing the Data Service extension on your cluster ${NC}\n"

if
    [[ $(az k8s-extension show --cluster-type connectedClusters -c $clusterName -g $groupName --name $extensionNameDataSvc | jq -r .installState) == "Installed" ]]
then
    echo "Extension already installed"
else
    az k8s-extension create -g $groupName --name $extensionNameDataSvc \
        --cluster-type connectedClusters -c $clusterName \
        --extension-type microsoft.arcdataservices \
        --auto-upgrade false \
        --scope cluster \
        --release-namespace $extensionNamespace \
        --config Microsoft.CustomLocation.ServiceAccount=sa-bootstrapper

    ### Looping until extention is installed
    while true
    do
        printf "${GREEN}\nChecking state of extension... ${NC}\n" 
        sleep 10
        installState=$(az k8s-extension show --cluster-type connectedClusters -c $clusterName -g $groupName --name $extensionNameDataSvc | jq -r .installState)
        printf "${GREEN}installState: ${installState} ${NC}\n"
        if
            [[ $installState == "Failed" ]]
        then
            exit
        elif
            [[ $installState == "Installed" ]]
        then
            break
        fi
    done
fi

extensionIdDataSvc=$(az k8s-extension show --cluster-type connectedClusters -c $clusterName -g $groupName --name $extensionNameDataSvc --query id -o tsv)

## Creating custom location with AppSvc extension
printf "${GREEN}Creating custom location ${NC}\n"

if
    [[ $(az customlocation show -g $groupName -n $customLocationName | jq -r .provisioningState) == "Succeeded" ]]
then
    echo "CustomLocation already exists"
else
    az customlocation create -g $groupName -n $customLocationName \
        --host-resource-id $connectedClusterId \
        --namespace $extensionNamespace -c $extensionIdAppSvc $extensionIdDataSvc

    ### Looping until custom location is provisioned
    while true
    do
        printf "${GREEN}\nChecking state of custom location... ${NC}\n" 
        sleep 10
        customLocationState=$(az customlocation show -g $groupName -n $customLocationName | jq -r .provisioningState)
        printf "${GREEN}customLocationState: ${customLocationState} ${NC}\n"
        if
            [[ $customLocationState == "Failed" ]]
        then
            exit
        elif
            [[ $customLocationState == "Succeeded" ]]
        then
            break
        fi
    done
fi

customLocationId=$(az customlocation show -g $groupName -n $customLocationName --query id -o tsv)

## Creating Kube-Environment
printf "${GREEN}Creating App Service Kubernetes environment ${NC}\n"

if
    [[ $(az appservice kube show -g $groupName -n $kubeEnvironmentName | jq -r .provisioningState) == "Succeeded" ]]
then
    echo "Kube environment already exists"
else
    az appservice kube create -g $groupName -n $kubeEnvironmentName \
        --custom-location $customLocationId --static-ip "$staticIp" \
        --location $location

    ### Looping until environment is ready
    while true
    do
        printf "${GREEN}\nChecking state of environment... ${NC}\n" 
        sleep 10
        kubeenvironmentState=$(az appservice kube show -g $groupName -n $kubeEnvironmentName | jq -r .provisioningState)
        printf "${GREEN}kubeenvironmentState: ${kubeenvironmentState} ${NC}\n"
        if
            [[ $kubeenvironmentState == "Failed" ]]
        then
            exit
        elif
            [[ $kubeenvironmentState == "Succeeded" ]]
        then
            break
        fi
    done
fi

### Creating Arc Data Controller
printf "${GREEN}Sleeping for 30 sec before creating Arc Data Controller ${NC}\n"

sleep 30

printf "${GREEN}Here we go...${NC}\n"

if
    [[ $(az resource show -g $groupName -n $dataControllerName --resource-type "Microsoft.AzureArcData/dataControllers" | jq -r .properties.provisioningState) == "Succeeded" ]]
then
    echo "Arc Data Controller already exists"
else
    az deployment group create -g $groupName --template-file arcDataController.json \
        --parameters \
            namespace="${extensionNamespace}" \
            connectionMode='direct' \
            location="${location}" \
            resourceGroup="${groupName}" \
            controllerName="${dataControllerName}" \
            administratorLogin="${azdata_username}" \
            administratorPassword="${azdata_password}" \
            customLocation="${customLocationId}" \
            uspClientId="${spClientId}" \
            uspTenantId="${spTenantId}" \
            uspClientSecret="${spSecret}" \
            uspAuthority="https://login.microsoftonline.com" \
            dockerImageTag="public-preview-may-2021" \
            storageClass="managed-premium" \
            serviceType="LoadBalancer" \
            logAnalyticsWorkspaceId="${logAnalyticsWorkspaceId}" \
            logAnalyticsPrimaryKey="${logAnalyticsKey}"

    ### Looping until ARM data controller is ready
    while true
    do
        printf "${GREEN}\nChecking state of data controller in Azure... ${NC}\n" 
        sleep 10
        dataControllerState=$(az resource show -g $groupName -n $dataControllerName --resource-type "Microsoft.AzureArcData/dataControllers" | jq -r .properties.provisioningState)
        printf "${GREEN}dataControllerState: ${dataControllerState} ${NC}\n"
        if
            [[ $dataControllerState == "Failed" ]]
        then
            exit
        elif
            [[ $dataControllerState == "Succeeded" ]]
        then
            break
        fi
    done

    ### Looping until K8 data controller is ready
    while true
    do
        printf "${GREEN}\nChecking state of data controller on K8... ${NC}\n" 
        sleep 10
        dataControllerState=$(az resource show -g $groupName -n $dataControllerName --resource-type "Microsoft.AzureArcData/dataControllers" | jq -r  .properties.k8sRaw.status.state)
        printf "${GREEN}dataControllerState: ${dataControllerState} ${NC}\n"
        if
            [[ $dataControllerState == "Failed" ]]
        then
            exit
        elif
            [[ $dataControllerState == "Ready" ]]
        then
            break
        fi
    done
fi

printf "${GREEN}Let's check if all the resource are ready...(Run 'kubectl get pods -n ${extensionNamespace}' to check again.) ${NC}\n"
kubectl get pods -n $extensionNamespace

printf "${GREEN}Whooo - congratulations! You made it all the way through - now go deploy apps!!! ${NC}\n"