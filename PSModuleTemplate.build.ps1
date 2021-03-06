<#
	.SYNOPSIS
	InvokeBuild Script to Build, Analyze & Test Module

	.DESCRIPTION
	This script is used as parto of the InvokeBuild module to automate the following steps:
		* Clean - ensuring we have a fresh space
		* Build - Create PSModule by combining classes, public & private into one psm1. This is also versioned based on your CI Engine
		* Analyze - Invoke PSScriptAnalyzer and throw if issues are raised
		* Test - Invoke pester tests and upload to your CI Engine

	.NOTES
	This is designed to be used in multiple projects. 
	It can be customized depending on requirments but should largely be left alone and kept generic. 
#>

Param (
	[Int]$BuildNumber,
	
	[ValidateSet('Local','Bamboo','AppVeyor')]
	[String]$CIEngine = 'Local', 

	[String]$DeployUrl,

	[String]$ApiKey
)

$ModuleName = 'PSModuleTemplate'
$Seperator = '------------------------------------------'
$RequiredModules = @('Pester', 'PSScriptAnalyzer','PlatyPS')
$SourcePath = "$PSScriptRoot\$ModuleName"
$OutputPath = "$env:ProgramFiles\WindowsPowerShell\Modules"

Task Build Init, {Clean}, Compile, GenerateDocs
Task BuildAndTest Init, {Clean}, Compile, Analyze, Test
Task BuildAndDeploy Init, {Clean}, Compile, Analyze, Test, Deploy, {Clean}

Function Clean {
	#Remove any previously loaded module versions from subsequent runs
	Get-Module -Name $ModuleName | Remove-Module

	#Remove any files previously compiled but leave other versions intact
	$Path = Join-Path -Path $OutputPath -ChildPath $ModuleName
	If ($PSVersionTable.PSVersion.Major -ge 5 ) {
		$Path = Join-Path -Path $Path -ChildPath $Script:Version.ToString()
	}
	Write-Output "Cleaning: $Path"
	$Path | Get-Item -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force
}

Task Init {
	$Seperator
	
	#Query the module manifest for information
	$ManifestPath = Join-Path -Path $SourcePath -ChildPath "$ModuleName.psd1"
	$Script:ManifestInfo = Test-ModuleManifest -Path $ManifestPath

	#Determine the new version. Major & Minor are set in the source psd1 file, BuildNumer is fed in as a parameter
	If ($BuildNumber) {
		$Script:Version = [Version]::New($ManifestInfo.Version.Major, $ManifestInfo.Version.Minor, $BuildNumber)
	}
	Else {
		$Script:Version = [Version]::New($ManifestInfo.Version.Major, $ManifestInfo.Version.Minor, 0)
	}

	Write-Output "Begining $CIEngine build of $ModuleName ($Version)"
	#Import required modules
	$RequiredModules | ForEach-Object {
		If (-not (Get-Module -Name $_ -ListAvailable)){
			Try {
				Write-Output "Installing Module: $_"
				Install-Module -Name $_ -Force
			}
			Catch {
				Throw "Unable to install missing module - $($_.Exception.Message)"
			}
		}

		Write-Output "Importing Module: $_"
		Import-Module -Name $_
	}
}

Task Compile {
	$Seperator
	
	Write-Output "Compiling Module..."
	#Depending on powershell version the module folder may or may not already exists after subsequent runs
	If (Test-Path -Path "$OutputPath\$ModuleName") {
		$Script:ModuleFolder = Get-Item -Path "$OutputPath\$ModuleName"
	}
	Else {
		$Script:ModuleFolder = New-Item -Path $OutputPath -Name $ModuleName -ItemType Directory
	}

	#Make a subfolder for the version if module is for powershell 5
	If ($PSVersionTable.PSVersion.Major -ge 5 ) {
		$Script:ModuleFolder = New-Item -Path $Script:ModuleFolder -Name $Version.ToString() -ItemType Directory
	}

	#Create root module psm1 file
	$ModuleContentParts = 'Classes', 'Private', 'Public' | ForEach-Object {
		Join-Path -Path $SourcePath -ChildPath $_ | Get-ChildItem -Recurse -Depth 1 -Include '*.ps1','*.psm1' | Get-Content -Raw
	}
	$ModuleContent = $ModuleContentParts -join "`r`n`r`n`r`n"
	$RootModule = New-Item -Path $ModuleFolder.FullName -Name "$ModuleName.psm1" -ItemType File -Value $ModuleContent

	#Copy module manifest and any other source files
	Write-Output "Copying other source files..."
	Get-ChildItem -Path $SourcePath -File | Where-Object {$_.Name -notin $RootModule.Name,"$ModuleName.init.ps1"} | Copy-Item -Destination $ModuleFolder.FullName
	Get-ChildItem -Path $SourcePath -Directory | Where-Object {$_.Name -notin 'Classes','Public','Private'} | Copy-Item -Destination $ModuleFolder.FullName -Recurse
	

	#Update module copied manifest
	$NewManifestPath = Join-Path -Path $ModuleFolder.FullName -ChildPath "$ModuleName.psd1"
	Write-Host "Updating Manifest ModuleVersion to $Script:Version"
	#Stupidly Update-ModuleManifest fails to correct the version when it doesnt match the folder its in. wtf?
	(Get-Content -Path $NewManifestPath) -replace "ModuleVersion = .+","ModuleVersion = '$Script:Version'" | Set-Content -Path $NewManifestPath

	$FunctionstoExport = Get-ChildItem -Path "$SourcePath\Public" -Filter '*.ps1' | Select-Object -ExpandProperty BaseName
	Write-Output "Updating Manifest FunctionsToExport to $FunctionstoExport"
	Update-ModuleManifest -Path $NewManifestPath -FunctionsToExport $FunctionstoExport
	
	#Update nuspec
	$NuspecPath = Join-Path -Path $ModuleFolder.FullName -ChildPath "$ModuleName.nuspec"
	(Get-Content -Path $NuspecPath) -replace "<version>__VERSION__</version>","<version>$Script:Version</version>" | Set-Content -Path $NuspecPath
}

Task Analyze {
	$Seperator
	Write-Output "Invoking PSScriptAnalyzer..."
	
	$AnalyzerIssues = Invoke-ScriptAnalyzer -Path $Script:ModuleFolder -Settings "$PSScriptRoot\ScriptAnalyzerSettings.psd1"

	If ($AnalyzerIssues) {
		Write-Warning "PSScriptAnalyzer has found the following issues:"
		$AnalyzerIssues
		Throw "Script analyzer returned issues!"
	}
	Else {
		Write-Output "No issues found"
	}
}

Task Test {
	$Seperator
	Write-Output "Invoking Pester..."

	Import-Module -Name $ModuleName
	$NUnitXml = Join-Path -Path $PSScriptRoot -ChildPath 'PesterOutput.xml'
	$TestResults = Invoke-Pester -Path $PSScriptRoot -PassThru -OutputFormat NUnitXml -OutputFile $NUnitXml

	#Upload tests to appveyor
	If ($CIEngine -eq 'AppVeyor') {
		Write-Output "Uploading test results to appveyor..."
		$WebClient = New-Object 'System.Net.WebClient'
		$WebClient.UploadFile("https://ci.appveyor.com/api/testresults/nunit/$($env:APPVEYOR_JOB_ID)","$NUnitXml" )
	}

	If ($TestResults.FailedCount -gt 0) {
		Throw "Failed $($TestResults.FailedCount) test(s)!"
	}
}

Task GenerateDocs {
	New-MarkdownHelp -Module $ModuleName -OutputFolder "$PSScriptRoot\docs" -Force -NoMetadata -WithModulePage
	Join-Path -Path $PSScriptRoot -ChildPath "docs\index.md" | Get-Item -ErrorAction SilentlyContinue | Remove-Item -Force
	Join-Path -Path $PSScriptRoot -ChildPath "docs\$ModuleName.md" | Rename-Item -NewName "index.md"
}

Task Deploy {
	$Nuspec = Join-Path -Path $Script:ModuleFolder -ChildPath "$ModuleName.nuspec" | Get-Item
	& NuGet.exe Pack $Nuspec.FullName

	$Nupkg = Join-Path -Path $PSScriptRoot -ChildPath "$ModuleName.$Script:Version.nupkg" | Get-Item
	& NuGet.exe Push $Nupkg.FullName -Source $DeployUrl -apikey $ApiKey
}
