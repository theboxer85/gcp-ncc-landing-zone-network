variable "project" {
  description = "Provider default project."
  type        = string
}

variable "prefix" {
  description = "Project ID prefix, passed to the config module."
  type        = string
}

variable "region" {
  description = "Default provider region."
  type        = string
  default     = "us-west4"
}

variable "cff_version" {
  description = "Cloud Foundation Fabric version."
  type        = string
  default     = "v57.0.0"
}

variable "project_id_overrides" {
  description = "project_ref -> project ID, replacing the IDs from the config module. Used to point every ref at a test project."
  type        = map(string)
  default     = {}
}
