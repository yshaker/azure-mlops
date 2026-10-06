variable "subscription_id" {
  type = string
}

variable "resource_group_name" {
  type        = string
  description = "Workload RG created by bootstrap (e.g. rg-churn-dev)"
}

variable "prefix" {
  type    = string
  default = "churn"
}

variable "compute_vm_size" {
  type    = string
  default = "Standard_DS3_v2"
}

variable "compute_max_nodes" {
  type    = number
  default = 2
}

variable "apim_sku" {
  type        = string
  default     = "Developer_1"
  description = "Developer_1 supports VNet integration but takes ~30-45 min to create. Consumption_0 is fast and cheap for learning."
}

variable "apim_publisher_email" {
  type = string
}

variable "public_network_access" {
  type        = bool
  default     = true
  description = "Learning default. Set false + add private endpoints for production (README step 11)."
}

# PHASE 2 — leave empty on the first apply. After the online endpoint exists,
# set this to its base URL (without /score) and apply again to wire up APIM.
variable "aml_endpoint_base_url" {
  type    = string
  default = ""
}
