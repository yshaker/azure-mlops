###############################################################################
# PHASE 2 — APIM API in front of the ML endpoint.
# Created only once var.aml_endpoint_base_url is set (the endpoint must exist
# first, and it is deployed by the MLOps pipeline).
###############################################################################

locals {
  wire_apim = var.aml_endpoint_base_url != ""
}

resource "azurerm_api_management_api" "churn" {
  count                 = local.wire_apim ? 1 : 0
  name                  = "churn-api"
  resource_group_name   = var.resource_group_name
  api_management_name   = azurerm_api_management.apim.name
  revision              = "1"
  display_name          = "Churn Prediction API"
  path                  = "churn"
  protocols             = ["https"]
  service_url           = var.aml_endpoint_base_url
  subscription_required = true # callers need an APIM subscription key
}

resource "azurerm_api_management_api_operation" "predict" {
  count               = local.wire_apim ? 1 : 0
  operation_id        = "predict"
  api_name            = azurerm_api_management_api.churn[0].name
  api_management_name = azurerm_api_management.apim.name
  resource_group_name = var.resource_group_name
  display_name        = "Predict churn"
  method              = "POST"
  url_template        = "/predict"
}

# The key policy: APIM gets an Entra ID token for https://ml.azure.com using
# its OWN managed identity and forwards it to the endpoint. The app never sees
# an ML key, and the endpoint never trusts anything but Entra ID tokens.
resource "azurerm_api_management_api_policy" "churn" {
  count               = local.wire_apim ? 1 : 0
  api_name            = azurerm_api_management_api.churn[0].name
  api_management_name = azurerm_api_management.apim.name
  resource_group_name = var.resource_group_name

  xml_content = <<-XML
    <policies>
      <inbound>
        <base />
        <!-- Throttle each consumer: 60 calls / minute per subscription key -->
        <rate-limit calls="60" renewal-period="60" />
        <!-- Reject oversized payloads before they reach the model -->
        <validate-content unspecified-content-type-action="prevent" max-size="102400" size-exceeded-action="prevent" errors-variable-name="requestBodyValidation">
          <content type="application/json" validate-as="json" action="ignore" />
        </validate-content>
        <!-- Passwordless auth to Azure ML -->
        <authentication-managed-identity resource="https://ml.azure.com" />
        <rewrite-uri template="/score" />
        <set-header name="Content-Type" exists-action="override">
          <value>application/json</value>
        </set-header>
      </inbound>
      <backend>
        <base />
      </backend>
      <outbound>
        <base />
        <set-header name="x-model-api" exists-action="override">
          <value>churn-v1</value>
        </set-header>
      </outbound>
      <on-error>
        <base />
      </on-error>
    </policies>
  XML
}

resource "azurerm_api_management_subscription" "test_app" {
  count               = local.wire_apim ? 1 : 0
  api_management_name = azurerm_api_management.apim.name
  resource_group_name = var.resource_group_name
  api_id              = replace(azurerm_api_management_api.churn[0].id, "/;rev=.*/", "")
  display_name        = "test-app"
  state               = "active"
}
