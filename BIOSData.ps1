Import-Module "$PSScriptRoot/Config.ps1" #Contains protected data (API Keys, URLs etc)


$headers=@{}
$headers.Add("accept", "application/json")
$headers.Add("Authorization", "Bearer $snipeAPIKey")

#These are the fields able to be set, use this array to set defaults - anything that has not value set upon processing will be ignored and thus no change will be made to existing data

$biosDetails =  @(
    #("USERDEVICE.label1",""), #Custom Field - Change "Label1" to what you want to call the field
    #("USERDEVICE.label2",""), #Custom Field - Change "Label2" to what you want to call the field
    #("USERDEVICE.label3",""), #Custom Field - Change "Label3" to what you want to call the field
    #("USERDEVICE.label4",""), #Custom Field - Change "Label4" to what you want to call the field
    #("USERDEVICE.label5",""), #Custom Field - Change "Label5" to what you want to call the field
    ("NETWORKCONNECTION.NUMNICS",""),
    ("NETWORKCONNECTION.GATEWAY",""),
    ("NETWORKCONNECTION.IPADDRESS",""),
    ("NETWORKCONNECTION.SUBNETMASK",""),
    ("NETWORKCONNECTION.SYSTEMNAME",""),
    ("NETWORKCONNECTION.LOGINNAME",""),
    ("PRELOADPROFILE.IMAGEDATE",""),
    ("PRELOADPROFILE.IMAGE",""),
    ("OWNERDATA.OWNERNAME",""),
    ("OWNERDATA.DEPARTMENT",""),
    ("OWNERDATA.LOCATION",""),
    ("OWNERDATA.PHONE_NUMBER",""),
    ("OWNERDATA.OWNERPOSITION",""),
    ("LEASEDATA.LEASE_START_DATE",""),
    ("LEASEDATA.LEASE_END_DATE",""),
    ("LEASEDATA.LEASE_TERM",""),
    ("LEASEDATA.LEASE_AMOUNT",""),
    ("LEASEDATA.LESSOR",""),
    ("USERASSETDATA.PURCHASE_DATE",""),
    ("USERASSETDATA.LAST_INVENTORIED",""),
    ("USERASSETDATA.WARRANTY_END",""),
    ("USERASSETDATA.WARRANTY_DURATION",""),
    ("USERASSETDATA.AMOUNT",""),
    ("USERASSETDATA.ASSET_NUMBER","")
)


$assetSerial = "R90YHGAH"

$response = ConvertFrom-Json((Invoke-WebRequest -Uri "$snipeURL/api/v1/hardware/byserial/$($assetSerial)" -Method GET -Headers $headers).Content)
if ($response.total -eq 1)
{
    $response = $response.rows[0]
    $asset.ASSET = $response.asset_tag
    $asset.CASES = (($response.custom_fields).'CASES Asset').value
    $asset.Name = $response.name
    $asset.Model = ($response.model).name#>
}
elseif ($response.total -gt 1)
{
    Write-Host "More than one item found with $($asset.SERIAL) continuing to next row"
    continue

}
else 
{
    Write-Host "No item found with $($asset.SERIAL) continuing to next row"
    continue
}



<#

$importFile = "Dymo.csv"

$assets = Import-CSV $importFile


foreach ($asset in $assets)
{
    $response = $null
    if ( -not [string]::IsNullOrWhiteSpace($asset.ASSET))
    {
        $response = ConvertFrom-Json((Invoke-WebRequest -Uri "$snipeURL/api/v1/hardware/bytag/$($asset.ASSET)" -Method GET -Headers $headers).Content)
        $asset.Serial = $response.serial
        $asset.CASES = (($response.custom_fields).'CASES Asset').value
        $asset.Name = $response.name
        $asset.Model = ($response.model).name
    }
    elseif ( -not [string]::IsNullOrWhiteSpace($asset.SERIAL))
    {
        $response = ConvertFrom-Json((Invoke-WebRequest -Uri "$snipeURL/api/v1/hardware/byserial/$($asset.SERIAL)" -Method GET -Headers $headers).Content)
        if ($response.total -eq 1)
        {
            $response = $response.rows[0]
            $asset.ASSET = $response.asset_tag
            $asset.CASES = (($response.custom_fields).'CASES Asset').value
            $asset.Name = $response.name
            $asset.Model = ($response.model).name
        }
        elseif ($response.total -gt 1)
        {
            Write-Host "More than one item found with $($asset.SERIAL) continuing to next row"
            continue

        }
        else 
        {
            Write-Host "No item found with $($asset.SERIAL) continuing to next row"
            continue
        }
        
    }

}

$assets #| Export-Csv -Path $importFile -NoTypeInformation#>