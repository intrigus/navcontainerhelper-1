﻿<#
 .Synopsis
  Download Artifacts
 .Description
  Download artifacts from artifacts storage
 .Parameter artifactUrl
  Url for application artifact to use.
 .Parameter includePlatform
  Add this switch to include the platform artifact in the download
 .Parameter force
  Add this switch to force download artifacts even though they already exists
 .Parameter forceRedirection
  Add this switch to force download redirection artifacts even though they already exists
 .Parameter basePath
  Load the artifacts into a file structure below this path. (default is c:\bcartifacts.cache)
 .Parameter timeout
  Timeout in seconds for each file download.
 .Example
  $artifactPaths = Download-Artifacts -artifactUrl $artifactUrl -includePlatform
  $appArtifactPath = $artifactPaths[0]
  $platformArtifactPath = $artifactPaths[1]
 .Example
  $appArtifactPath = Download-Artifacts -artifactUrl $artifactUrl
#>
function Download-Artifacts {
    Param (
        [Parameter(Mandatory=$true)]
        [string] $artifactUrl,
        [switch] $includePlatform,
        [switch] $force,
        [switch] $forceRedirection,
        [string] $basePath = 'c:\bcartifacts.cache',
        [int]    $timeout = 300
    )

    if (-not (Test-Path $basePath)) {
        New-Item $basePath -ItemType Directory | Out-Null
    }

    do {
        $redir = $false
        $appUri = [Uri]::new($artifactUrl)

        $appArtifactPath = Join-Path $basePath $appUri.AbsolutePath
        $exists = Test-Path $appArtifactPath
        if ($exists -and $force) {
            Remove-Item $appArtifactPath -Recurse -Force
            $exists = $false
        }
        if ($exists -and $forceRedirection) {
            $appManifestPath = Join-Path $appArtifactPath "manifest.json"
            $appManifest = Get-Content $appManifestPath | ConvertFrom-Json
            if ($appManifest.PSObject.Properties.name -eq "applicationUrl") {
                # redirect artifacts are always downloaded
                Remove-Item $appArtifactPath -Recurse -Force
                $exists = $false
            }
        }
        if (-not $exists) {
            Write-Host "Downloading application artifact $($appUri.AbsolutePath)"
            $appZip = Join-Path ([System.IO.Path]::GetTempPath()) "$([Guid]::NewGuid().ToString()).zip"
            try {
                TestSasToken -sasToken $artifactUrl
                Download-File -sourceUrl $artifactUrl -destinationFile $appZip -timeout $timeout
            }
            catch {
                if ($artifactUrl.Contains('.azureedge.net/')) {
                    $artifactUrl = $artifactUrl.Replace('.azureedge.net/','.blob.core.windows.net/')
                    Write-Host "Retrying download..."
                    Download-File -sourceUrl $artifactUrl -destinationFile $appZip -timeout $timeout
                }
            }
            Write-Host "Unpacking application artifact"
            try {
                if (Test-Path "$appArtifactPath-tmp") {
                    Remove-Item -Path "$appArtifactPath-tmp" -Recurse -Force
                }
                Expand-Archive -Path $appZip -DestinationPath "$appArtifactPath-tmp" -Force
                Rename-Item -Path "$appArtifactPath-tmp" -NewName ([System.IO.Path]::GetFileName($appArtifactPath)) -Force
            }
            finally {
                Remove-Item -path $appZip -force
            }
        }
        Set-Content -Path (Join-Path $appArtifactPath 'lastused') -Value "$([datetime]::UtcNow.Ticks)"

        $appManifestPath = Join-Path $appArtifactPath "manifest.json"
        $appManifest = Get-Content $appManifestPath | ConvertFrom-Json

        if ($appManifest.PSObject.Properties.name -eq "applicationUrl") {
            $redir = $true
            $artifactUrl = $appManifest.ApplicationUrl
            if ($artifactUrl -notlike 'https://*') {
                $artifactUrl = "https://$($appUri.Host)/$artifactUrl$($appUri.Query)"
            }
        }

    } while ($redir)

    $appArtifactPath

    if ($includePlatform) {
        if ($appManifest.PSObject.Properties.name -eq "platformUrl") {
            $platformUrl = $appManifest.platformUrl
        }
        else {
            $platformUrl = "$($appUri.AbsolutePath.Substring(0,$appUri.AbsolutePath.LastIndexOf('/')))/platform".TrimStart('/')
        }
    
        if ($platformUrl -notlike 'https://*') {
            $platformUrl = "https://$($appUri.Host.TrimEnd('/'))/$platformUrl$($appUri.Query)"
        }
        $platformUri = [Uri]::new($platformUrl)
         
        $platformArtifactPath = Join-Path $basePath $platformUri.AbsolutePath
        $exists = Test-Path $platformArtifactPath
        if ($exists -and $force) {
            Remove-Item $platformArtifactPath -Recurse -Force
            $exists = $false
        }
        if (-not $exists) {
            Write-Host "Downloading platform artifact $($platformUri.AbsolutePath)"
            $platformZip = Join-Path ([System.IO.Path]::GetTempPath()) "$([Guid]::NewGuid().ToString()).zip"
            try {
                TestSasToken -sasToken $artifactUrl
                Download-File -sourceUrl $platformUrl -destinationFile $platformZip -timeout $timeout
            }
            catch {
                if ($platformUrl.Contains('.azureedge.net/')) {
                    $platformUrl = $platformUrl.Replace('.azureedge.net/','.blob.core.windows.net/')
                    Write-Host "Retrying download..."
                    Download-File -sourceUrl $platformUrl -destinationFile $platformZip -timeout $timeout
                }
            }
            Write-Host "Unpacking platform artifact"
            try {
                if (Test-Path "$platformArtifactPath-tmp") {
                    Remove-Item -Path "$platformArtifactPath-tmp" -Recurse -Force
                }
                Expand-Archive -Path $platformZip -DestinationPath "$platformArtifactPath-tmp" -Force
                Rename-Item -Path "$platformArtifactPath-tmp" -NewName ([System.IO.Path]::GetFileName($platformArtifactPath)) -Force
            }
            finally {
                Remove-Item -path $platformZip -force
            }
    
            $prerequisiteComponentsFile = Join-Path $platformArtifactPath "Prerequisite Components.json"
            if (Test-Path $prerequisiteComponentsFile) {
                $prerequisiteComponents = Get-Content $prerequisiteComponentsFile | ConvertFrom-Json
                Write-Host "Downloading Prerequisite Components"
                $prerequisiteComponents.PSObject.Properties | % {
                    $path = Join-Path $platformArtifactPath $_.Name
                    if (-not (Test-Path $path)) {
                        $dirName = [System.IO.Path]::GetDirectoryName($path)
                        $filename = [System.IO.Path]::GetFileName($path)
                        if (-not (Test-Path $dirName)) {
                            New-Item -Path $dirName -ItemType Directory | Out-Null
                        }
                        $url = $_.Value
                        Download-File -sourceUrl $url -destinationFile $path -timeout $timeout
                    }
                }
                $dotnetCoreFolder = Join-Path $platformArtifactPath "Prerequisite Components\DotNetCore"
                if (!(Test-Path $dotnetCoreFolder)) {
                    New-Item $dotnetCoreFolder -ItemType Directory | Out-Null
                    Download-File -sourceUrl "https://go.microsoft.com/fwlink/?LinkID=844461" -destinationFile (Join-Path $dotnetCoreFolder "DotNetCore.1.0.4_1.1.1-WindowsHosting.exe") -timeout $timeout
                }
            }
        }
        Set-Content -Path (Join-Path $platformArtifactPath 'lastused') -Value "$([datetime]::UtcNow.Ticks)"
        $platformArtifactPath
    }
}
Export-ModuleMember -Function Download-Artifacts
