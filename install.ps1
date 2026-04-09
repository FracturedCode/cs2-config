#### script setup

$ErrorActionPreference = "Stop"

function Get-SteamLoginUserMap {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SteamRoot
    )

    $loginUsersPath = Join-Path $SteamRoot "config/loginusers.vdf"
    $loginMap = @{}

    if (-not (Test-Path $loginUsersPath)) {
        return $loginMap
    }

    $content = Get-Content $loginUsersPath -Raw

    $userBlocks = [regex]::Matches($content, '"(\d+)"\s*\{([^}]*)\}', 'Singleline')
    foreach ($match in $userBlocks) {
        $steamId64 = $match.Groups[1].Value
        $block = $match.Groups[2].Value

        $accountName = ([regex]::Match($block, '"AccountName"\s*"([^"]+)"')).Groups[1].Value
        $personaName = ([regex]::Match($block, '"PersonaName"\s*"([^"]+)"')).Groups[1].Value

        if ($steamId64 -match '^\d+$') {
            $accountId = ([int64]$steamId64 - 76561197960265728).ToString()

            $loginMap[$accountId] = @{
                AccountName = $accountName
                PersonaName = $personaName
            }
        }
    }

    return $loginMap
}

if ($IsWindows) {
    $steamRoot = (Get-ItemProperty -Path "HKCU:\Software\Valve\Steam").SteamPath
}
elseif ($IsLinux) {
    # Common Linux paths
    $candidates = @(
        "$HOME/.steam/steam",
        "$HOME/.local/share/Steam"
    )
    $steamRoot = $candidates | Where-Object { Test-Path $_ } | Select-Object -First 1
}
else {
    throw "Unsupported OS"
}

#### find localconfig.vdf

$loginMap = Get-SteamLoginUserMap -SteamRoot $steamRoot
$userdata = Join-Path $steamRoot "userdata"
$configs = Get-ChildItem -Path $userdata -Directory -ErrorAction Stop |
    ForEach-Object {
        $p = Join-Path $_.FullName "config\localconfig.vdf"
        if (Test-Path $p) { $p }
    }

if ($configs.Count -eq 0) {
    throw "No localconfig.vdf found under $userdata"
}
elseif ($configs.Count -eq 1) {
    $configPath = $configs[0]
    $userId = (Get-Item $configPath).Directory.Parent.Name
    Write-Host "Using only found config: $configPath"
}
else {
    Write-Host "Multiple Steam user configs found:`n"

    for ($i = 0; $i -lt $configs.Count; $i++) {
        $path = $configs[$i]
        $candidateUserId = (Get-Item $path).Directory.Parent.Name
        $userInfo = $loginMap[$candidateUserId]

        if ($userInfo) {
            $displayName = "$($userInfo.PersonaName) ($($userInfo.AccountName))"
        }
        else {
            $displayName = "Unknown ($candidateUserId)"
        }

        Write-Host "[$i] $displayName"
        Write-Host "    Path: $path"
    }

    do {
        $selection = Read-Host "`nEnter the number of the Steam account to use"
    } while (
        -not ($selection -as [int]) -or
        [int]$selection -lt 0 -or
        [int]$selection -ge $configs.Count
    )

    $configPath = $configs[[int]$selection]
    $userId = (Get-Item $configPath).Directory.Parent.Name
}

Write-Host "`nSelected config: $configPath"
Write-Host "Selected user id: $userId"

#### install user-specific autoexec cfg

Write-Host "Installing autoexec.cfg"
$cfgDir = Join-Path $steamRoot "steamapps/common/Counter-Strike Global Offensive/game/csgo/cfg"
if (-not (Test-Path $cfgDir)) {
    throw "CS2 cfg directory not found: $cfgDir"
}

$autoexecFileName = "autoexec.$userId.cfg"
$autoexecDest = Join-Path $cfgDir $autoexecFileName
$autoexecSrc = Join-Path $pwd "autoexec.cfg"

if (-not (Test-Path $autoexecSrc)) {
    throw "Source autoexec.cfg not found in current directory: $autoexecSrc"
}

if (Test-Path $autoexecDest) {
    Remove-Item -Path $autoexecDest -Force
}

$createSymlinkCmd = "New-Item -Path `"$autoexecDest`" -Value `"$autoexecSrc`" -ItemType SymbolicLink -Force"
if ($IsWindows) {
	sudo powershell -Command "$createSymlinkCmd" # windows requires admin to symlink
} else {
	Invoke-Expression "$createSymlinkCmd"
}

Write-Host "Installed $autoexecFileName -> $autoexecSrc"

#### Backup
$bakPath = Split-Path -Path $configPath -Leaf
$bakPath = Join-Path $pwd "$bakPath.$userId.bak"
Copy-Item $configPath $bakPath -Force

#### add user-specific autoexec cfg to launch options

$content = Get-Content $configPath -Raw
$launchOptionToAdd = "+exec $autoexecFileName"

# Look for app 730 LaunchOptions and append the user-specific +exec if missing.
# This is regex-based and works only if the file layout is reasonably normal.
$pattern = '("730"\s*\{(?:[^{}]|\{[^{}]*\})*?"LaunchOptions"\s*")([^"]*)(")'

if ($content -match $pattern) {
    $current = $matches[2]
    $escapedFileName = [regex]::Escape($autoexecFileName)
    $execPattern = "(?i)(^|\s)\+exec\s+$escapedFileName($|\s)"

    if ($current -notmatch $execPattern) {
        $newValue = ($current.Trim() + " $launchOptionToAdd").Trim()
        $content = [regex]::Replace($content, $pattern, "`$1$newValue`$3", 1)
        Set-Content -Path $configPath -Value $content -NoNewline
        Write-Host "Updated LaunchOptions for app 730 in $configPath"
    } else {
        Write-Host "Launch option already present."
    }
} else {
    Write-Warning "Could not find a LaunchOptions entry for app 730. Open CS2 Properties once in Steam, then try again."
}