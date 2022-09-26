[Parameter(Mandatory)]
[string]$PathToTemplateFiles,
[Parameter(Mandatory)]
[string]$CustomerSubscriptionId,
[Parameter(Mandatory)]
[string]$CustomerSubscriptionName,
[Parameter(Mandatory)]
[string]$CustomerShortName


#Where To Save the Template Files
$PathToTemplateFiles = 'C:\Temp\'

#Customer (to be managed) Subscription Info
$CustomerSubscriptionId = "subscription id"
$CustomerSubscriptionName = "subscription name"

#Managed Service Provider (MSP) Subscription Info 
$SubscriptionName = "subscription name"
$Location = "australiasoutheast"

$AdminGroup = "Customer1Admins" #Azure AD admin group in the Managed Service Provider(MSP) tenant
$AdminGroupMember = Get-AzureADUser -SearchString "User Display Name" #That will manage customer resources
$MSPOfferName = "$(CustomerShortName) Lighthouse MSP Access" #The name that appears in the customers lighthouse portal, must be unique


#Log into the MSP Subscription with Connect-AzAccount since we're not using Cloud Shell
Import-Module Az -Verbose

Clear-AzContext
Connect-AzAccount
$AZSubscription = Get-AzSubscription -SubscriptionName $SubscriptionName

#Confirm the MSP subscription is selected before continuing
Get-AzContext

#Connect to the MSP Subscription Azure AD Tenant
Get-AzSubscription -SubscriptionName $SubscriptionName | Set-AzContext -Force -Verbose
Connect-AzureAD -TenantId $AzSubscription.TenantId

#Register the Microsoft.ManagedServices Provider 
Register-AzResourceProvider -ProviderNamespace Microsoft.ManagedServices


<#
Retrieve role definition IDs that will be assigned in the customer environment
* Edit the list as required
* Can only use built in roles
* The roles “Owner” and “User Access Administrator” cannot be used 
* (Except in the last line of the JSON template where they're used to allow the MSP to grant limited access to Service Principals in the Customer tenant)
* Ref https://docs.microsoft.com/en-us/azure/lighthouse/how-to/onboard-customer
#>
$SecurityAdminRole = (Get-AzRoleDefinition -Name 'Security Admin')
$ReaderRole = (Get-AzRoleDefinition -Name 'Reader')
$UserAccessAdminRole = (Get-AzRoleDefinition -Name 'User Access Administrator')
$ContributorRole = (Get-AzRoleDefinition -Name 'Contributor')
$LogAnalyticsContributorRole = (Get-AzRoleDefinition -Name 'Log Analytics Contributor')
$AzSubscriptionId = $AzSubscription.id


<#
Check for or Create the Lighthouse Admin Group
* This group resides in the MSP tenant
* This group will be granted access to the 'Customer1' subscription
* In order to add Lighthouse permissions for an Azure AD group, the Group type must be set to Security
* Ref https://docs.microsoft.com/en-us/azure/lighthouse/how-to/onboard-customer
#>

#Check for an existing group
$AdminGroupId = (Get-AzureAdGroup -SearchString $AdminGroup).ObjectId

#OR Create a new group, add the admin user and assign Reader Role rights
New-AzureADGroup -DisplayName $AdminGroup -MailEnabled $false -SecurityEnabled $true -MailNickName "NotSet" -Description "Used to enable lighthouse access to customer resources"
Add-AzureADGroupMember -ObjectId $AdminGroupId -RefObjectId $AdminGroupMember.objectId
New-AzRoleAssignment -ObjectId $AdminGroupId -RoleDefinitionName $ReaderRole.name -Scope "/subscriptions/$AzSubscriptionId"

#Check the group members
Get-AzureADGroupMember -ObjectId $AdminGroupId


#Download the Lighthouse Subscription Delegation Templates
#Ref & More Templates: https://docs.microsoft.com/en-us/azure/lighthouse/how-to/onboard-customer#create-your-template-manually
New-Item -Path $PathToTemplateFiles -Name "Lighthouse" -ItemType "directory"
Invoke-WebRequest -Uri 'https://raw.githubusercontent.com/Azure/Azure-Lighthouse-samples/master/templates/delegated-resource-management/subscription/subscription.json' -OutFile $PathToTemplateFiles\Lighthouse\subscription.json -ErrorAction Stop -Verbose
Invoke-WebRequest -Uri 'https://raw.githubusercontent.com/Azure/Azure-Lighthouse-samples/master/templates/delegated-resource-management/subscription/subscription.parameters.json' -OutFile $PathToTemplateFiles\Lighthouse\subscription.parameters.json -ErrorAction Stop -Verbose

<#
Update the Lighthouse Template Parameters.json file
Will grant the MSP AdminGroup Reader & Security Admin Rights in the Customer Subscription Once Applied
NB Each authorization in the template includes a principalId which refers to an Azure AD user, group, or service principal in the MSP tenant. 
In this demo principalId refers to the Customer1Admins Group
#>

(Get-Content -Path $PathToTemplateFiles\Lighthouse\subscription.parameters.json -Raw) | ForEach-Object {
    $_ -replace 'Axians Managed Services', $MSPOfferName `
        -replace '<insert managing tenant id>', $AzSubscription.TenantId `
        -replace '00000000-0000-0000-0000-000000000000', $AdminGroupId `
        -replace 'PIM_Group', $AdminGroup `
        -replace 'acdd72a7-3385-48ef-bd42-f606fba81ae7', $SecurityAdminRole.id `
        -replace '91c1777a-f3dc-4fae-b103-61d183457e46', $ReaderRole.id `
        -replace '18d7d88d-d35e-4fb5-a5c3-7773c20a72d9', $UserAccessAdminRole.id `
        -replace 'b24988ac-6180-42a0-ab88-20f7382dd24c', $ContributorRole.id `
        -replace '92aaf0da-9dab-42b6-94a3-d43ce8d16293', $LogAnalyticsContributorRole.id
} | Set-Content -Path $PathToTemplateFiles\lighthouse\subscription.parameters.json


<#
* Switch to the Customer Subscription - this is what the subscription owner will need to run to delegate access to the MSP
* Log in as an account who has a role with the 'Microsoft.Authorization/roleAssignments/write permission' for eg: Owner
* Log in first with Connect-AzAccount since we're not using Cloud Shell
* Sometimes its easiest to start a new terminal if you're having login issues or getting weird errors
#>
Clear-AzContext
Connect-AzAccount 
Get-AzSubscription -SubscriptionName $CustomerSubscriptionName | Set-AzContext -Force -Verbose

$CustomerAZSubscription = Get-AzSubscription -SubscriptionName $CustomerSubscriptionName
Connect-AzureAD -TenantId $CustomerAzSubscription.TenantId

#Confirm the correct subscription is selected before continuing
Get-AzContext

#Deploy Azure Resource Manager template using template and parameter file locally
New-AzSubscriptionDeployment -Name DeployServiceProviderTemplate `
    -Location $Location `
    -TemplateFile $PathToTemplateFiles\Lighthouse\subscription.json `
    -TemplateParameterFile $PathToTemplateFiles\Lighthouse\subscription.parameters.json `
    -Verbose

#Confirm Successful Onboarding for Azure Lighthouse
Get-AzManagedServicesDefinition | Format-List
Get-AzManagedServicesAssignment | Format-List

#In about 15 minutes the MSP should be visible in the Customer Subscription
Start-Process "https://portal.azure.com/#blade/Microsoft_Azure_CustomerHub/ServiceProvidersBladeV2/providers"