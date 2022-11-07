#requires -version 2
<#
.SYNOPSIS
  Reads Snipe-IT for machine data, then uses this data to build an array of information to set the BIOS fields on a Lenovo Device compatible with WinAIA
  Other functions pull from MDT data and the environment to fill in more data

.DESCRIPTION

.PARAMETER <Parameter_Name>
  <Brief description of parameter input required. Repeat this attribute if required>

.INPUTS
    Serial number of device (pulled from BIOS)
    Data from Snipe-IT
    
.OUTPUTS
    Laptop sync to Intune if assigned, if not script to do it on first login
  
.NOTES
  Version:        1.0
  Author:         Justin Simmonds
  Creation Date:  2022-10-05
  Purpose/Change: Initial script development
  
.EXAMPLE
  
#>

#---------------------------------------------------------[Initialisations]--------------------------------------------------------

#Set Error Action to Silently Continue
$ErrorActionPreference = "SilentlyContinue"

#Dot Source required Function Libraries

#Modules
Import-Module "$PSScriptRoot/Config.ps1" #Contains protected data (API Keys, URLs etc)
#Import-Module "$PSScriptRoot/DevEnv.ps1" -Force ##Temporary Variables used for development and troubleshooting

#----------------------------------------------------------[Declarations]----------------------------------------------------------

$sLogFile = Join-Path -Path $sLogPath -ChildPath $sLogName


# These are the fields able to be set, use this array to set defaults - anything that has not value set upon processing will be ignored and thus no change will be made to existing data. To Blank the field please set to BLANK (Case Sesnsive)
$biosDetails =  @{
    "NETWORKCONNECTION.NUMNICS"=""
    "NETWORKCONNECTION.GATEWAY"=""
    "NETWORKCONNECTION.IPADDRESS"=""
    "NETWORKCONNECTION.SUBNETMASK"=""
    "NETWORKCONNECTION.SYSTEMNAME"=""
    "NETWORKCONNECTION.LOGINNAME"=""
    "PRELOADPROFILE.IMAGEDATE"=""
    "PRELOADPROFILE.IMAGE"=""
    "OWNERDATA.OWNERNAME"="Western Port Secondary College"
    "OWNERDATA.DEPARTMENT"="ICT Department"
    "OWNERDATA.LOCATION"="Hastings, Victoria, Australia"
    "OWNERDATA.PHONE_NUMBER"="03 5979 1577"
    "OWNERDATA.OWNERPOSITION"=""
    "LEASEDATA.LEASE_START_DATE"=""
    "LEASEDATA.LEASE_END_DATE"=""
    "LEASEDATA.LEASE_TERM"=""
    "LEASEDATA.LEASE_AMOUNT"=""
    "LEASEDATA.LESSOR"=""
    "USERASSETDATA.PURCHASE_DATE"=""
    "USERASSETDATA.LAST_INVENTORIED"=""
    "USERASSETDATA.WARRANTY_END"=""
    "USERASSETDATA.WARRANTY_DURATION"=""
    "USERASSETDATA.AMOUNT"=""
    "USERASSETDATA.ASSET_NUMBER"=""
}

$biosCurrent = @{}

# Decomission Task Sequence ID's - this is used to blank the data
$decomIDs = @(
    'DECOM'
)

#Script Variables - Declared to stop it being generated multiple times per run
$script:snipeResult = $null #Blank Snipe result

#-----------------------------------------------------------[Functions]------------------------------------------------------------

function Write-Log ($logMessage)
{
    Write-Host "$(Get-Date -UFormat '+%Y-%m-%d %H:%M:%S') - $logMessage"
}

function Set-ImageData
{
    $biosDetails.'PRELOADPROFILE.IMAGE' = $env:_SMSTSPackageID
    $biosDetails.'PRELOADPROFILE.IMAGEDATE' = "$(Get-Date -format "yyyyMMdd")"
}

function Set-Inventoried
{
    $biosDetails.'USERASSETDATA.LAST_INVENTORIED' = "$(Get-Date -format "yyyyMMdd")"
}

function Get-SnipeData
{
    # Retrieve Serial from BIOS
    $deviceSerial = (Get-CimInstance win32_bios | Select serialnumber).serialnumber
    #$deviceSerial = $devSerial
    
    $script:snipeResult = $null #Blank Snipe result

    $checkURL=$snipeURL.Substring((Select-String 'http[s]:\/\/' -Input $snipeURL).Matches[0].Length)

    if ($checkURL.IndexOf('/') -eq -1)
    {
        #Test ICMP connection
        if ((Test-Connection -TargetName $checkURL))
        {
            Write-Log "Successfully to Snipe-IT server at address $checkURL"
        }
        else 
        {
            Write-Log "Cannot connect to Snipe-IT server at address $checkURL exiting"
            exit
        }
    }

    #Create Snipe Headers
    $snipeHeaders=@{}
    $snipeHeaders.Add("accept", "application/json")
    $snipeHeaders.Add("Authorization", "Bearer $snipeAPIKey")

    try 
    {
        $script:snipeResult = Invoke-WebRequest -Uri "$snipeURL/api/v1/hardware/byserial/$deviceSerial" -Method GET -Headers $snipeHeaders

        if ($script:snipeResult.StatusCode -eq 200)
        {
            #Covert from result to JSON content
            $script:snipeResult = ConvertFrom-JSON($script:snipeResult.Content)

            if ($script:snipeResult.total -eq 1)
            {
                Write-Log "Sucessfully retrieved device information for $deviceSerial from Snipe-IT"
                $script:snipeResult = $script:snipeResult.rows[0]
                $biosDetails.'USERASSETDATA.ASSET_NUMBER' = $script:snipeResult.asset_tag
                $biosDetails.'USERASSETDATA.PURCHASE_DATE' = "$(Get-Date (($script:snipeResult.Purchase_Date).date) -format "yyyyMMdd")"
                $biosDetails.'USERASSETDATA.WARRANTY_END' = "$(Get-Date (($script:snipeResult.Warranty_Expires).date) -format "yyyyMMdd")"
                $biosDetails.'USERASSETDATA.AMOUNT' = "`$$($script:snipeResult.purchase_cost)"
                $biosDetails.'USERASSETDATA.WARRANTY_DURATION' = ($script:snipeResult.Warranty_Months).Split(' ')[0]
                $biosDetails.'NETWORKCONNECTION.SYSTEMNAME' = $script:snipeResult.name
            }
            elseif ($script:snipeResult.total -eq 0)
            {
                Write-Log "Device $deviceSerial does not exist in Snipe-IT, Exiting"
                Exit
            }
            else 
            {
                Write-Log "More than one device with $deviceSerial exists in Snipe-IT, Exiting"
                Exit
            }
            
        }
        else 
        {
            Write-Log "Cannot retrieve device $deviceSerial from Snipe-IT due to unknown error, exiting"
            exit
        }
    }
    catch 
    {
        Write-Log $_.Exception
        exit
    }
}

function New-CustomField
{
    Param(
        [string]$fieldKey, #Appended to the USERDEVICE domain
        [string]$fieldValue #Value the field should contain
    ) #end param
    
    # Validate Input and output error if not valid
    if ([string]::IsNullOrWhiteSpace($fieldKey))
    {
        Write-Log "Cannot create custom field as no valid field name was provided"
        return
    }

    if ([string]::IsNullOrWhiteSpace($fieldValue))
    {
        Write-Log "Cannot create custom field $fieldKey as no valid field data was provided"
        return
    }

    # Check the number of custom fields as 5 is the max, see if they are all used, if not create the field and add it to the hastable
    if ($script:customFieldsUsed -lt 5)
    {
        $biosDetails.Add("USERDEVICE.$fieldKey", $fieldValue)
        $script:customFieldsUsed++
    }
    else 
    {
        Write-Log "Cannot create custom field $fieldKey as all possible custom fields used"
    }

}

function Set-BIOSData
{
    #Write-Log

    foreach ($field in ($biosDetails.GetEnumerator() | Sort-Object Key))
    {
        #Write-Host ($biosCurrent.($field.Key))
        
        if (-not [string]::IsNullOrWhiteSpace($field.Value) -and ($biosCurrent.Keys -notcontains $field.Key -or ($biosCurrent.Keys -contains $field.Key -and ($biosCurrent.($field.Key)) -ne $field.Value)))
        {
            
            .\WinAIA64.exe -silent -set "`"$($field.Key)=$($field.Value)`""

        }
    }
}

function Get-CurrentBIOSData
{
    $script:customFieldsUsed = 0
    .\WinAIA64.exe -silent -output-file "$PSScriptRoot\output.txt" -get

    foreach($row in (Get-Content -Path "$PSScriptRoot\output.txt" | Sort-Object))
    {
        $script:tempData = $null
        $script:tempData = $row.Split('=')
        $biosCurrent.Add($script:tempData[0], $script:tempData[1])
    }

    foreach ($record in $biosCurrent.GetEnumerator())
    {
        if ($record.Key -like "USERDEVICE.*" -and $biosDetails.Keys -notcontains $record.Key)
        {
            Write-Host $record.Key
            $script:customFieldsUsed++
        }

    }

    Write-Log "Currently $script:customFieldsUsed custom data fields are used"
    
}

#-----------------------------------------------------------[Execution]------------------------------------------------------------

#Log-Start -LogPath $sLogPath -LogName $sLogName -ScriptVersion $sScriptVersion

#Set snipeResult to null and declare here so data can be passed to other functions if needed

Get-CurrentBIOSData

Get-SnipeData
Set-ImageData
Set-Inventoried
New-CustomField -fieldKey "ITAM_NUMBER" -fieldValue $snipeResult.custom_fields.'ITAM Number'.Value
New-CustomField -fieldKey "CASES_ASSET" -fieldValue $snipeResult.custom_fields.'CASES Asset'.Value
Set-BIOSData

# TODO
# Automate Pull of current BIOS info
# Push info to BIOS
# Check to ensure that the manafacturer is LENOVO and the model is supported
# DECOM
# Set data into BIOS where appropriate
# Add Loggings Notes
# Add Deletion of temporary output file
# Add Download and extract of WinAIA