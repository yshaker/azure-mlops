output "resource_group" { value = var.resource_group_name }
output "aml_workspace" { value = azurerm_machine_learning_workspace.mlw.name }
output "compute_cluster" { value = azurerm_machine_learning_compute_cluster.cpu.name }
output "storage_account" { value = azurerm_storage_account.lake.name }
output "key_vault" { value = azurerm_key_vault.kv.name }
output "app_insights" { value = azurerm_application_insights.appi.name }

# Endpoint names must be unique per region, so reuse the random suffix.
output "suggested_endpoint_name" { value = "churn-${random_string.suffix.result}" }

output "apim_gateway_url" { value = azurerm_api_management.apim.gateway_url }

output "apim_predict_url" {
  value = local.wire_apim ? "${azurerm_api_management.apim.gateway_url}/churn/predict" : "not wired yet (phase 2)"
}

output "apim_test_subscription_key" {
  value     = local.wire_apim ? azurerm_api_management_subscription.test_app[0].primary_key : ""
  sensitive = true
}
