using namespace System.Net

# Input bindings are passed in via param block.
param($QueueItem, $TriggerMetadata)

$Request = $QueueItem

$WebhookTable = Get-CIPPTable -TableName webhookTable
$Webhooks = Get-AzDataTableEntity @WebhookTable
Write-Host 'Received request'
Write-Host "CIPPID: $($request.Query.CIPPID)"
$url = ($request.headers.'x-ms-original-url').split('/API') | Select-Object -First 1
Write-Host $url
if ($Request.query.CIPPID -in $Webhooks.RowKey) {
    Write-Host 'Found matching CIPPID'
    $Webhookinfo = $Webhooks | Where-Object -Property RowKey -EQ $Request.query.CIPPID

    if ($Request.Query.Type -eq 'GraphSubscription') {
        # Graph Subscriptions
        [pscustomobject]$ReceivedItem = $Request.Body.value
        Invoke-CippGraphWebhookProcessing -Data $ReceivedItem -CIPPID $request.Query.CIPPID -WebhookInfo $Webhookinfo

    } else {
        # Auditlog Subscriptions
        try {
            foreach ($ReceivedItem In ($Request.body)) {
                $ReceivedItem = [pscustomobject]$ReceivedItem
                Write-Host "Received Item: $($ReceivedItem | ConvertTo-Json -Depth 15 -Compress))"
                $TenantFilter = (Get-Tenants | Where-Object -Property customerId -EQ $ReceivedItem.TenantId).defaultDomainName
                Write-Host "Webhook TenantFilter: $TenantFilter"
                $ConfigTable = get-cipptable -TableName 'SchedulerConfig'
                $Alertconfig = Get-CIPPAzDataTableEntity @ConfigTable | Where-Object { $_.Tenant -eq $TenantFilter -or $_.Tenant -eq 'AllTenants' }
                $Operations = ($AlertConfig.if | ConvertFrom-Json -ErrorAction SilentlyContinue).selection, 'UserLoggedIn'
                $Webhookinfo = $Webhooks | Where-Object -Property RowKey -EQ $Request.query.CIPPID
                #Increased download efficiency: only download the data we need for processing. Todo: Change this to load from table or dynamic source.
                $MappingTable = [pscustomobject]@{
                    'UserLoggedIn'                               = 'Audit.AzureActiveDirectory'
                    'Add member to role.'                        = 'Audit.AzureActiveDirectory'
                    'Disable account.'                           = 'Audit.AzureActiveDirectory'
                    'Update StsRefreshTokenValidFrom Timestamp.' = 'Audit.AzureActiveDirectory'
                    'Enable account.'                            = 'Audit.AzureActiveDirectory'
                    'Disable Strong Authentication.'             = 'Audit.AzureActiveDirectory'
                    'Reset user password.'                       = 'Audit.AzureActiveDirectory'
                    'Add service principal.'                     = 'Audit.AzureActiveDirectory'
                    'HostedIP'                                   = 'Audit.AzureActiveDirectory'
                    'badRepIP'                                   = 'Audit.AzureActiveDirectory'
                    'UserLoggedInFromUnknownLocation'            = 'Audit.AzureActiveDirectory'
                    'customfield'                                = 'AnyLog'
                    'anyAlert'                                   = 'AnyLog'
                    'New-InboxRule'                              = 'Audit.Exchange'
                    'Set-InboxRule'                              = 'Audit.Exchange'
                }
                #Compare $Operations to $MappingTable. If there is a match, we make a new variable called $LogsToDownload
                #Example: $Operations = 'UserLoggedIn', 'Set-InboxRule' makes : $LogsToDownload = @('Audit.AzureActiveDirectory',Audit.Exchange)
                $LogsToDownload = $Operations | Where-Object { $MappingTable.$_ } | ForEach-Object { $MappingTable.$_ }
                if ($ReceivedItem.ContentType -in $LogsToDownload -or $LogsToDownload -contains 'AnyLog') {
                    $Data = New-GraphPostRequest -type GET -uri "https://manage.office.com/api/v1.0/$($ReceivedItem.tenantId)/activity/feed/audit/$($ReceivedItem.contentid)" -tenantid $TenantFilter -scope 'https://manage.office.com/.default'
                } else {
                    Write-Host "No data to download for $($ReceivedItem.ContentType)"
                    continue
                }
                Write-Host "Data found: $($data.count) items"
                $DataToProcess = $Data | Where-Object -Property Operation -In $Operations
                Write-Host "Data to process found: $($DataToProcess.count) items"
                foreach ($Item in $DataToProcess) {
                    Write-Host "Processing $($item.operation)"
                    Invoke-CippWebhookProcessing -TenantFilter $TenantFilter -Data $Item -CIPPPURL $url
                } 
            }
        } catch {
            Write-Host "Webhook Failed: $($_.Exception.Message)"
        }
    }

} else {
    Write-Host 'Unauthorised Webhook'
}
