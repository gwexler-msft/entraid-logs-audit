<#
.SYNOPSIS
    azd postprovision hook — surfaces the remaining manual post-deploy steps.

.DESCRIPTION
    Runs automatically after `azd provision` / `azd up`. All connectivity is now
    identity-based and fully provisioned by Bicep, so there is no connection key
    to wire up:
      * AzureWebJobsStorage  -> managed identity (rbac.bicep)
      * Event Hub trigger    -> managed identity (rbac.bicep, connections.json)
      * ACS Email send       -> managed identity via the ACS REST API; the
                                workflow Send_email HTTP action authenticates
                                with audience https://communication.azure.com,
                                and rbac.bicep grants Contributor on the ACS
                                resource.

    The only steps that cannot be automated here are listed at the end.
#>
$ErrorActionPreference = 'Stop'

Write-Host '==> postprovision: connectivity is identity-based; no secrets to wire.' -ForegroundColor Green
Write-Host ''
Write-Host 'Next steps (not automated):' -ForegroundColor Yellow
Write-Host '  1. azd deploy logsprocessor   # from a VNet-connected host (the site is private)'
Write-Host '  2. Configure Entra ID tenant Diagnostic Settings -> raw Event Hub (deployment guide section 7)'
