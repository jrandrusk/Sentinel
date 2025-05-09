# Parameters
$tenantId = ""
$clientId = ""
$clientSecret = ""
$subscriptionId = ""
$resourceGroupName = ""
$workspaceName = ""
$watchlistAlias = "RetiredWindowsServers"
$searchKey = "Name"  # Must match the watchlist's SearchKey column
$apiVersion = "2023-02-01"

# Sample data source (replace with your data retrieval logic, e.g., Azure AD query)
# For this example, we use a CSV file with columns: UserPrincipalName, DisplayName
$dataSource = @"
Name
MickeyMouse
"@ | ConvertFrom-Csv

# Validate data source
if (-not $dataSource -or $dataSource.Count -eq 0) {
    Write-Error "Data source is empty or invalid"
    exit
}
Write-Output "Data Source: $($dataSource | ConvertTo-Json)"

# Authenticate to Azure AD
$tokenUrl = "https://login.microsoftonline.com/$tenantId/oauth2/v2.0/token"
$body = @{
    client_id     = $clientId
    scope         = "https://management.azure.com/.default"
    client_secret = $clientSecret
    grant_type    = "client_credentials"
}
try {
    $response = Invoke-RestMethod -Uri $tokenUrl -Method Post -Body $body
    $accessToken = $response.access_token
    Write-Output "Authentication successful"
} catch {
    Write-Error "Authentication failed: $($_.Exception.Message)"
    exit
}

# API base URL
$baseUrl = "https://management.azure.com/subscriptions/$subscriptionId/resourceGroups/$resourceGroupName/providers/Microsoft.OperationalInsights/workspaces/$workspaceName/providers/Microsoft.SecurityInsights/watchlists/$watchlistAlias"

# Headers
$headers = @{
    Authorization = "Bearer $accessToken"
    "Content-Type" = "application/json"
}

# Step 1: Get existing watchlist items
$existingItemsUrl = "$baseUrl/watchlistItems?api-version=$apiVersion"
$existingItems = @()
try {
    $response = Invoke-RestMethod -Uri $existingItemsUrl -Headers $headers -Method Get
    $existingItems = $response.value | ForEach-Object { $_.properties.itemsKeyValue.$searchKey }
    Write-Output "Retrieved $($existingItems.Count) existing items"
} catch {
    Write-Error "Failed to retrieve watchlist items: $($_.Exception.Message)"
    Write-Output "Full error: $($_.Exception | Format-List -Force | Out-String)"
    exit
}

# Step 2: Add or update watchlist items
$newItemsAdded = 0
foreach ($item in $dataSource) {
    $serverName = $item.Name

    # Validate item data
    if (-not $serverName) {
        Write-Warning "Skipping invalid item: Name=$serverName"
        continue
    }

    # Skip if item exists
    if ($existingItems -contains $serverName) {
        Write-Output "Skipping $serverName (already exists)"
        continue
    }

    # Prepare payload
    try {
        $itemPayload = @{
            properties Wrote
            = @{
                itemsKeyValue = @{
                    $searchKey = $serverName
                }
            }
        } | ConvertTo-Json -Depth 10
        Write-Output "Payload for $serverName: $itemPayload"
    } catch {
        Write-Error "Failed to create payload for $serverName: $($_.Exception.Message)"
        continue
    }

    # Validate JSON
    try {
        $null = $itemPayload | ConvertFrom-Json
    } catch {
        Write-Error "Invalid JSON payload for $serverName: $($_.Exception.Message)"
        continue
    }

    # Generate item ID
    $itemId = $serverName -replace '[^a-zA-Z0-9_-]', '_'  # Replace invalid characters
    if (-not $itemId) {
        Write-Error "Invalid item ID for $serverName: $itemId"
        continue
    }
    Write-Output "Item ID: $itemId"

    # Add item
    $addItemUrl = "$baseUrl/watchlistItems/$itemId?api-version=$apiVersion"
    Write-Output "API URL: $addItemUrl"
    try {
        $response = Invoke-RestMethod -Uri $addItemUrl -Headers $headers -Method Put -Body $itemPayload
        Write-Output "Added $serverName to watchlist"
        $newItemsAdded++
    } catch {
        Write-Error "Failed to add $serverName: $($_.Exception.Message)"
        Write-Output "Full error: $($_.Exception | Format-List -Force | Out-String)"
    }
    Start-Sleep -Milliseconds 200  # Avoid rate limits
}

# Step 3: Optional - Remove outdated items
$itemsToRemove = $existingItems | Where-Object { $_ -notin $dataSource.Name }
foreach ($item in $itemsToRemove) {
    $itemId = $item -replace '[^a-zA-Z0-9_-]', '_'
    $deleteItemUrl = "$baseUrl/watchlistItems/$itemId?api-version=$apiVersion"
    try {
        Invoke-RestMethod -Uri $deleteItemUrl -Headers $headers -Method Delete
        Write-Output "Removed $item from watchlist"
    } catch {
        Write-Error "Failed to remove $item: $($_.Exception.Message)"
    }
}

# Summary
Write-Output "Update complete. Added $newItemsAdded new items. Removed $($itemsToRemove.Count) outdated items."
