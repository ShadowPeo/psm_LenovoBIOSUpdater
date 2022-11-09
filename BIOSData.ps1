#requires -version 2
<#
.SYNOPSIS
  Reads Snipe-IT for machine data, then uses this data to build an array of information to set the BIOS fields on a Lenovo Device compatible with WinAIA
  Other functions pull from MDT data and the environment to fill in more data

  Program needs to run as admin to do extraction

.DESCRIPTION

.PARAMETER <Parameter_Name>
  <Brief description of parameter input required. Repeat this attribute if required>

.INPUTS
    Serial number of device (pulled from BIOS)
    Data from Snipe-IT
    
.OUTPUTS
    Data into the BIOS about the machine
  
.NOTES
  Version:        1.0
  Author:         Justin Simmonds
  Creation Date:  2022-11-07
  Purpose/Change: Initial script development
  
.EXAMPLE
  
#>

#---------------------------------------------------------[Initialisations]--------------------------------------------------------

#Set Error Action to Silently Continue
$ErrorActionPreference = "SilentlyContinue"

#Dot Source required Function Libraries

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
    "OWNERDATA.OWNERNAME"=""
    "OWNERDATA.DEPARTMENT"=""
    "OWNERDATA.LOCATION"=""
    "OWNERDATA.PHONE_NUMBER"=""
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

#WinAIA Locations
$winAIAPath = "$($env:ProgramData)\Lenovo\WinAIA"
$winAIAPackage= "giaw03ww.exe"
$winAIAInternet = "https://download.lenovo.com/pccbbs/mobiles"

#Script Variables - Declared to stop it being generated multiple times per run
$script:snipeResult = $null #Blank Snipe result

#DryRun Settings
$dryRun = $false

#-----------------------------------------------------------[Functions]------------------------------------------------------------

function Write-Log ($logMessage)
{
    Write-Host "$(Get-Date -UFormat '+%Y-%m-%d %H:%M:%S') - $logMessage"
}
function Write-LogBreak ($logMessage)
{
    Write-Host "--------------------------------------------------------------------------------------"
}


function Set-ImageData
{
    $biosDetails.'PRELOADPROFILE.IMAGE' = $TSEnv:TASKSEQUENCEID
    $biosDetails.'PRELOADPROFILE.IMAGEDATE' = "$(Get-Date -format "yyyyMMdd")"
}

function Set-Inventoried
{
    $biosDetails.'USERASSETDATA.LAST_INVENTORIED' = "$(Get-Date -format "yyyyMMdd")"
}

function Get-SnipeData
{
    Write-LogBreak
    Write-Log "Retrieving device details from Snipe-IT"
    
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
    if ([string]::IsNullOrWhiteSpace($fieldKey) -and $biosCurrent.Keys -notcontains "USERDEVICE.$fieldKey")
    {
        Write-LogBreak
        Write-Log "Attempting to create a new Custom Field"
        Write-Log "Cannot create custom field as no valid field name was provided"
        return
    }

    if ([string]::IsNullOrWhiteSpace($fieldValue))
    {
        Write-LogBreak
        Write-Log "Cannot create/update custom field $fieldKey as no valid field data was provided"
        return
    }

    # Check the number of custom fields as 5 is the max, see if they are all used, if not create the field and add it to the hastable
    if ($script:customFieldsUsed -lt 5)
    {
        if ($biosCurrent.Keys -contains "USERDEVICE.$fieldKey" -and $biosCurrent."USERDEVICE.$fieldKey" -ne $fieldValue)
        {
            Write-LogBreak
            Write-Log "Updating Custom Field $fieldKey"
            $biosDetails.Add("USERDEVICE.$fieldKey", $fieldValue)
        }
        elseif ($biosCurrent.Keys -notcontains "USERDEVICE.$fieldKey")
        {
            Write-Log "Creating custom field $fieldKey"
            $biosDetails.Add("USERDEVICE.$fieldKey", $fieldValue)
            $script:customFieldsUsed++
        }
    }
    else 
    {
        Write-Log "Cannot create custom field $fieldKey as all possible custom fields used"
    }

}

function Set-BIOSData
{
    Write-LogBreak
    if ($dryRun -eq $false)
    {
        Write-Log "Setting BIOS Data - Commiting to BIOS"
    }
    else 
    {
        Write-Log "Setting BIOS Data - Dry Run"
    }
    Write-LogBreak

    $noRows = $true
    foreach ($field in ($biosDetails.GetEnumerator() | Sort-Object Key))
    {
        if (-not [string]::IsNullOrWhiteSpace($field.Value) -and ($biosCurrent.Keys -notcontains $field.Key -or ($biosCurrent.Keys -contains $field.Key -and ($biosCurrent.($field.Key)) -ne $field.Value)))
        {
            $noRows = $false
            if ($dryRun -eq $false)
            {
                if ($field.Value -ne "BLANK")
                {
                    Write-Log "Setting $($field.Key) to $($field.Value)"
                    .\WinAIA64.exe -silent -set "`"$($field.Key)=$($field.Value)`""
                }
                elseif ($field.Value -eq "BLANK" -and $biosCurrent.Keys -contains $field.Key)
                {
                    Write-Log "Setting $($field.Key) to $($field.Value)"
                    .\WinAIA64.exe -silent -set "`"$($field.Key)=`""
                }
            }
            else
            {
                Write-Log "Setting $($field.Key) to $($field.Value)"
            }

        }
    }

    if ($noRows -eq $true)
    {
        Write-Log "All data fields are up to date, do not need to write anything"
    }
}

#Retrieve the current BIOS data from the machine using WinAIA, outputting it to a text file, importing the text file (utility does not send back to stdout) splitting the line at the = and adding the data to a hashtable for data comparison. 
#Current data is written to log as it is read, custom values are counted so that we do not try to set more than the allowed custom values (5)
function Get-CurrentBIOSData
{
    Write-LogBreak
    Write-Log "Retrieving current BIOS data"
    Write-LogBreak

    $script:customFieldsUsed = 0
    if (Test-Path -Path "output.txt")
    {
        Write-Log "Removing previously generated BIOS Settings output file"
        Remove-Item "output.txt"
    }

    try 
    {

        .\WinAIA64.exe -silent -output-file "output.txt" -get

        if (Test-Path -Path "output.txt")
        {
            foreach($row in (Get-Content -Path "output.txt" | Sort-Object))
            {
                $tempData = $null
                $tempData = $row.Split('=')
                $biosCurrent.Add($tempData[0], $tempData[1])
                Write-Log "Setting $($tempData[0]) is currently set to $($tempData[1])"
            }

            foreach ($record in $biosCurrent.GetEnumerator())
            {
                if ($record.Key -like "USERDEVICE.*" -and $biosDetails.Keys -notcontains $record.Key)
                {
                    $script:customFieldsUsed++
                }

            }

            Write-Log "Currently $script:customFieldsUsed custom data fields are used"
            Write-Log "Removing generated BIOS Settings output file"
            Remove-Item "output.txt"

        }
        else 
        {
            Write-Log "There was an error retrieving the current BIOS Data, continuing with no data"
        }
    }
    catch 
    {
        Write-Log "There was an error retrieving the current BIOS Data, exiting"
        Exit
    }
    
}

#-----------------------------------------------------------[Execution]------------------------------------------------------------

#Log-Start -LogPath $sLogPath -LogName $sLogName -ScriptVersion $sScriptVersion

#Modules - Imported here to override defaults
Import-Module "$PSScriptRoot/Config.ps1" -Force #Contains protected data (API Keys, URLs etc)
#Import-Module "$PSScriptRoot/DevEnv.ps1" -Force ##Temporary Variables used for development and troubleshooting

# Retrieve Serial from BIOS
$deviceSerial = (Get-CimInstance win32_bios | Select-Object serialnumber).serialnumber
#$deviceSerial = $devSerial

Write-LogBreak
if (-not [string]::IsNullOrWhiteSpace($deviceSerial))
{
    Write-Log "Lenovo BIOS Data Update Script"
    Write-Log "Running on device with serial number $deviceSerial"
    Write-LogBreak
    Write-Log "Serial ($deviceSerial) retrieved from BIOS"
}
else 
{
    Write-Log "Cannot retrieve serial from BIOS, exiting"
    Write-LogBreak
    Exit
}

# Check that the system in manufactured by Lenovo
If (((Get-CimInstance -ClassName Win32_ComputerSystem).Manufacturer) -ne "LENOVO")
{
    Write-Log "This is not a Lenovo device it is manafactured by $((Get-CimInstance -ClassName Win32_ComputerSystem).Manufacturer), exiting"
    Exit
}

Write-LogBreak
Write-Log "Checking if WinAIA Utility Exists"

# Check WinAIA exists, if not attempt to download it
if (-not (Test-Path "$winAIAPath/WinAIA64.exe" -PathType Leaf))
{
    Write-Log "WinAIA not found, downloading"

    # Create temp directory for utility and log output file
    if (!(Test-Path -Path $winAIAPath)) {
        New-Item -Path $winAIAPath -ItemType Directory -ErrorAction SilentlyContinue | Out-Null
        Write-Log "Creating Lenovo Directory"
    }

    try
    {
        if (-not [string]::IsNullOrWhiteSpace($winAIACache) -and (Test-Path "$winAIACache\$winAIAPackage" -PathType Leaf))
        {
            Write-Log "Cache Location specified and found, trying to pull from cache"
            try 
            {
                Copy-Item "$winAIACache/$winAIAPackage" -Destination $winAIAPath
            }
            catch
            {
                $_.Exception.Response.StatusCode.Value__
            }
        }
        else 
        {
            Write-Log "Cache Location not specified or found, trying to pull from internet"
            try 
            {
                Invoke-WebRequest -Uri "$winAIAInternet/$winAIAPackage" -OutFile "$winAIAPath/$winAIAPackage" | Out-Null    
            }
            catch 
            {
                $_.Exception.Response.StatusCode.Value__
            }
        }
        
        if (Test-Path("$winAIAPath/$winAIAPackage"))
        {
            Write-Log "Retrieved WinAIA package, trying to extract"
            try 
            {
                Start-Process "$winAIAPath/$winAIAPackage" -ArgumentList "/VERYSILENT /DIR=.\ /EXTRACT=YES" -Wait
                if (Test-Path "$winAIAPath/WinAIA64.exe" -PathType Leaf)
                {
                    Write-Log "WinAIA successfully extracted, continuing"
                }
                else 
                {
                    Write-Log "WinAIA unsuccessfully extracted, exiting"
                    Exit
                }
            }
            catch 
            {
                $_.Exception.Response.StatusCode.Value__
            }
        }
        else 
        {
            Write-Log "Unable to retrieve WinAIA package, exiting"
            Exit
        }

    }
    catch
    {
        $_.Exception.Response.StatusCode.Value__
    }
}
else 
{
    Write-Log "WinAIA Found, Continuing"
}

#Set location to AIA Path
Set-Location -Path $winAIAPath

#Get Current BIOS Data
Get-CurrentBIOSData

#Insert data if not decomissioning
if ([string]::IsNullOrWhiteSpace($TSEnv:TASKSEQUENCEID))
{
    Write-LogBreak
    Write-Log "Processing Tasks - Inventory"
    Write-LogBreak
    Write-Log "This is a non-decommission run, setting data"
    Get-SnipeData
    Set-Inventoried
    New-CustomField -fieldKey "ITAM_NUMBER" -fieldValue $snipeResult.custom_fields.'ITAM Number'.Value
    New-CustomField -fieldKey "CASES_ASSET" -fieldValue $snipeResult.custom_fields.'CASES Asset'.Value    

}
elseif (-not [string]::IsNullOrWhiteSpace($TSEnv:TASKSEQUENCEID) -and $decomIDs -notcontains $TSEnv:TASKSEQUENCEID)
{
    Write-LogBreak
    Write-Log "Processing Tasks - Imaging"
    Write-LogBreak
    Write-Log "This is a non-decommission run, setting data"
    Get-SnipeData
    Set-ImageData
    Set-Inventoried
    New-CustomField -fieldKey "ITAM_NUMBER" -fieldValue $snipeResult.custom_fields.'ITAM Number'.Value
    New-CustomField -fieldKey "CASES_ASSET" -fieldValue $snipeResult.custom_fields.'CASES Asset'.Value
}
else 
{
    Write-LogBreak
    Write-Log "Processing Tasks - Decommissioning"
    Write-LogBreak
    Write-Log "This is a decommission run, blanking all data and setting asset tag to DECOM"

    
    # Cycle through all default BIOS details and blank them
    foreach ($key in $($biosDetails.Keys))
    {
        $biosDetails.$key = "BLANK"
    }
    
    # Cycle through current BIOS keys in case there are custom fields not catered for in the default fields, if there are, add them to the bios details to set and set the fields to blank
    foreach ($field in $biosCurrent.GetEnumerator())
    {
        if($biosDetails.Keys -notcontains $field.Key)
        {
            $biosDetails.Add(($field.Key), "BLANK")
        }
    }

    $biosDetails.'USERASSETDATA.ASSET_NUMBER' = "DECOM"

}

#Set BIOS Data
Set-BIOSData

Write-LogBreak
Write-Log "BIOS Data checks complete, exiting"
Write-LogBreak