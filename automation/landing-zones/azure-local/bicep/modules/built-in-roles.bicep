// Built-in Azure RBAC role definition IDs used by this landing zone (design §6.2, keyvault-and-secrets.md §4).
// These GUIDs are Azure platform constants (identical in every tenant), not tenant data; they are the only
// GUIDs allowed in this solution and this file is the documented allow-list for the secrets sweep.
// Test-LandingZone.ps1 check "role-map" verifies every entry against the tenant's role definitions.
@export()
var builtInRoles = {
  Owner: '8e3af657-a8ff-443c-a75c-2fe8c4bcb635'
  Contributor: 'b24988ac-6180-42a0-ab88-20f7382dd24c'
  Reader: 'acdd72a7-3385-48ef-bd42-f606fba81ae7'
  RoleBasedAccessControlAdministrator: 'f58310d9-a9f6-439a-9e8d-f62e7b41a168'
  NetworkContributor: '4d97b98b-1d4f-4787-a291-c67834d212e7'
  KeyVaultSecretsOfficer: 'b86a8fe4-44ce-4948-aee5-eccb2c155cd7'
  KeyVaultSecretsUser: '4633458b-17de-408a-b874-0445c86b69e6'
  KeyVaultCertificatesOfficer: 'a4417e6f-fecd-4de8-b567-7b0420556985'
  KeyVaultContributor: 'f25e0fa2-a7c8-4377-a976-54943a77a395'
  KeyVaultDataAccessAdministrator: '8b54135c-b56d-4d72-a534-26097cfdc8d8'
  StorageAccountContributor: '17d1049b-9a84-46fb-8f53-869881c3d3ab'
  AzureConnectedMachineOnboarding: 'b64e21ea-ac4e-4cdf-9dc9-5b892992bee7'
  AzureConnectedMachineResourceAdministrator: 'cd570a14-e51a-42ad-bac8-bafd67325302'
  AzureConnectedMachineResourceManager: 'f5819b54-e033-4d82-ac66-4fec3cbf3f4c'
  AzureStackHCIAdministrator: 'bda0d508-adf1-4af0-9c28-88919fc3ae06'
  AzureStackHCIVMContributor: '874d1c73-6003-4e60-a13a-cb31ea190a85'
  AzureStackHCIVMReader: '4b3fe76c-f777-4d24-a2d7-b027b0f7b273'
  LogAnalyticsReader: '73c42c96-874c-492b-b04d-ab87d138a893'
  LogAnalyticsContributor: '92aaf0da-9dab-42b6-94a3-d43ce8d16293'
  MonitoringReader: '43d0d8ad-25c7-4714-9337-8ba259a9fe05'
  MonitoringContributor: '749f88d5-cbae-40b8-bcfc-e573ddc772fa'
}

// Roles the deployment identity may assign or remove (design §6.2: RBAC Administrator "constrained to the roles in this table").
@export()
var deployIdentityAssignableRoles = [
  builtInRoles.Reader
  builtInRoles.KeyVaultSecretsUser
  builtInRoles.KeyVaultSecretsOfficer
  builtInRoles.KeyVaultCertificatesOfficer
  builtInRoles.StorageAccountContributor
  builtInRoles.AzureConnectedMachineOnboarding
  builtInRoles.AzureConnectedMachineResourceAdministrator
  builtInRoles.AzureConnectedMachineResourceManager
  builtInRoles.AzureStackHCIAdministrator
  builtInRoles.AzureStackHCIVMContributor
  builtInRoles.AzureStackHCIVMReader
  builtInRoles.LogAnalyticsReader
  builtInRoles.LogAnalyticsContributor
  builtInRoles.MonitoringReader
  builtInRoles.MonitoringContributor
  builtInRoles.Contributor
]
