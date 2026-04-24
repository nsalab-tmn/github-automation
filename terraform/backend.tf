terraform {
  backend "azurerm" {
    resource_group_name  = "rg-sandbox-terraform-uks-01"
    storage_account_name = "stsndbxghtfstate01"
    container_name       = "tfstate"
    key                  = "github-automation.tfstate"
    use_azuread_auth     = true
  }
}
