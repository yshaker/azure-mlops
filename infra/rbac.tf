###############################################################################
# Managed identity role assignments — who can do what, with no secrets.
###############################################################################

# Compute cluster identity: read/write training data, pull images.
resource "azurerm_role_assignment" "compute_blob" {
  scope                = azurerm_storage_account.lake.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = azurerm_user_assigned_identity.compute.principal_id
}

resource "azurerm_role_assignment" "compute_acr" {
  scope                = azurerm_container_registry.acr.id
  role_definition_name = "AcrPull"
  principal_id         = azurerm_user_assigned_identity.compute.principal_id
}

# APIM identity: allowed to do exactly ONE thing — score online endpoints in
# this workspace. A custom role is tighter than "AzureML Data Scientist",
# which would also let APIM submit jobs, read data, etc.
resource "azurerm_role_definition" "endpoint_scorer" {
  name        = "AML Endpoint Scorer (${random_string.suffix.result})"
  scope       = data.azurerm_resource_group.rg.id
  description = "Can invoke Azure ML online endpoints, nothing else."

  permissions {
    actions = [
      "Microsoft.MachineLearningServices/workspaces/onlineEndpoints/score/action",
    ]
  }

  assignable_scopes = [data.azurerm_resource_group.rg.id]
}

resource "azurerm_role_assignment" "apim_scorer" {
  scope              = azurerm_machine_learning_workspace.mlw.id
  role_definition_id = azurerm_role_definition.endpoint_scorer.role_definition_resource_id
  principal_id       = azurerm_api_management.apim.identity[0].principal_id
}
