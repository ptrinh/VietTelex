$ErrorActionPreference = 'Stop'

# Bumped by windows/installer/chocolatey/update.sh - keep these three lines in this form.
$version       = '1.3.28'
$checksumX64   = 'FC78D0B0ED08AA6DFE474E31DEFBC80B51DB0EEA15A81F40DD96059A3FE00A65'
$checksumArm64 = 'E14972EF235747C9730A1641119CF0D675217BDC9FB853AC1132ECFF8B74488A'

$base = "https://github.com/ptrinh/viettelex/releases/download/windows-v$version"

# Install-ChocolateyPackage only knows 32/64-bit, and there is no 32-bit VietTelex.
# On Windows on ARM choco.exe may run emulated (x64), where PROCESSOR_ARCHITECTURE
# reads AMD64, so take the NATIVE architecture from the machine environment key
# (not WOW-redirected). The ARM64 MSI is required there: it carries the ARM64X
# forwarder that serves both native ARM64 and emulated x64 apps.
$nativeArch = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Environment' -Name PROCESSOR_ARCHITECTURE).PROCESSOR_ARCHITECTURE
if ($nativeArch -eq 'ARM64') {
  $url64 = "$base/VietTelex-$version-arm64.msi"; $checksum64 = $checksumArm64
} else {
  $url64 = "$base/VietTelex-$version-x64.msi";   $checksum64 = $checksumX64
}

$packageArgs = @{
  packageName    = $env:ChocolateyPackageName
  fileType       = 'msi'
  url64bit       = $url64
  checksum64     = $checksum64
  checksumType64 = 'sha256'
  softwareName   = 'VietTelex*'
  silentArgs     = "/qn /norestart /l*v `"$($env:TEMP)\$($env:ChocolateyPackageName).$($env:ChocolateyPackageVersion).MsiInstall.log`""
  validExitCodes = @(0, 3010, 1641)
}

Install-ChocolateyPackage @packageArgs
