variable "checkmarx_project_name" {
  description = "The name of the Checkmarx One project"
  type        = string
  default     = "my-terraform-project"
}

variable "checkmarx_group" {
  description = "The Checkmarx One group or team"
  type        = string
  default     = "Infrastructure"
}

variable "checkmarx_branch" {
  description = "The branch name for the scan"
  type        = string
  default     = "main"
}
