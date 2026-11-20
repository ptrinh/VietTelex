$ErrorActionPreference = 'Stop'

# Bumped by windows/installer/chocolatey/update.sh - keep these three lines in this form.
$version       = '1.3.30'
$checksumX64   = '1AC086FFE3849AF2EC71D9624C2CBD248A733C5223F095CF078D5D116E0E72C7'
$checksumArm64 = '25DDAB20FBB9C5C1DD854BF6E971C54898EB72DB3C402DAF0A22C9BAA2FF5E84'

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
