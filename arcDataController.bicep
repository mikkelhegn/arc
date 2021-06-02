param namespace string
param connectionMode string
param controllerName string
param administratorLogin string

@secure()
param administratorPassword string
param customLocation string
param uspClientId string
param uspTenantId string

@secure()
param uspClientSecret string
param uspAuthority string
param resourceTags object
param dockerImageTag string
param storageClass string
param serviceType string

resource controllerName_resource 'Microsoft.AzureArcData/dataControllers@2021-03-02-preview' = {
  name: controllerName
  location: 'eastus'
  extendedLocation: {
    name: customLocation
    type: 'CustomLocation'
  }
  tags: resourceTags
  properties: {
    basicLoginInformation: {
      username: administratorLogin
      password: administratorPassword
    }
    uploadServicePrincipal: {
      clientId: uspClientId
      tenantId: uspTenantId
      authority: uspAuthority
      clientSecret: uspClientSecret
    }
    k8sRaw: {
      apiVersion: 'arcdata.microsoft.com/v1alpha1'
      kind: 'datacontroller'
      spec: {
        credentials: {
          controllerAdmin: 'controller-login-secret'
          dockerRegistry: 'arc-private-registry'
          domainServiceAccount: 'domain-service-account-secret'
          serviceAccount: 'sa-mssql-controller'
        }
        docker: {
          imagePullPolicy: 'Always'
          imageTag: dockerImageTag
          registry: 'mcr.microsoft.com'
          repository: 'arcdata'
        }
        security: {
          allowDumps: true
          allowNodeMetricsCollection: true
          allowPodMetricsCollection: true
          allowRunAsRoot: false
        }
        services: [
          {
            name: 'controller'
            port: 30080
            serviceType: serviceType
          }
          {
            name: 'serviceProxy'
            port: 30777
            serviceType: serviceType
          }
        ]
        settings: {
          ElasticSearch: {
            'vm.max_map_count': '-1'
          }
          azure: {
            connectionMode: connectionMode
            location: 'westeurope'
            resourceGroup: 'm0520-02-lima-rg'
            subscription: 'c484c80e-0a6f-4470-86de-697ecee16984'
          }
          controller: {
            displayName: controllerName
            enableBilling: 'True'
            'logs.rotation.days': '7'
            'logs.rotation.size': '5000'
          }
        }
        storage: {
          data: {
            accessMode: 'ReadWriteOnce'
            className: storageClass
            size: '15Gi'
          }
          logs: {
            accessMode: 'ReadWriteOnce'
            className: storageClass
            size: '10Gi'
          }
        }
      }
      metadata: {
        namespace: namespace
        name: 'datacontroller'
      }
    }
  }
}