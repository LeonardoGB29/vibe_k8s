[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$region = 'us-east-1'
$expectedAccount = '911045829576'
$localPort = 16443
$instanceName = 'vibe-desarrollo-k3s-server'
$promptedForCredentials = $false

trap {
    if ($promptedForCredentials) {
        Remove-Item Env:\AWS_ACCESS_KEY_ID, Env:\AWS_SECRET_ACCESS_KEY, Env:\AWS_SESSION_TOKEN, Env:\AWS_DEFAULT_REGION -ErrorAction SilentlyContinue
    }
    throw
}

function Get-AwsAccountId {
    $account = & aws sts get-caller-identity --query Account --output text 2>$null
    if ($LASTEXITCODE -ne 0) { return $null }
    return "$account".Trim()
}

Write-Host 'Conexion SSM al API de Kubernetes de VIBE' -ForegroundColor Cyan
$remoteHost = Read-Host 'DNS o IP privado del API/servidor K3s (vacio = detectar automaticamente)'
$portText = Read-Host 'Puerto remoto del API Kubernetes [6443]'
if ([string]::IsNullOrWhiteSpace($portText)) { $portText = '6443' }
$remotePort = 0
if (-not [int]::TryParse($portText, [ref]$remotePort) -or $remotePort -lt 1 -or $remotePort -gt 65535) {
    throw 'El puerto debe ser un numero entre 1 y 65535.'
}

$accountId = Get-AwsAccountId
if (-not $accountId) {
    Write-Host 'Introduce las credenciales temporales de AWS Academy (AWS Details > AWS CLI > Show).' -ForegroundColor Yellow
    $env:AWS_ACCESS_KEY_ID = Read-Host 'AWS Access Key ID'
    $secretSecure = Read-Host 'AWS Secret Access Key (entrada oculta)' -AsSecureString
    $env:AWS_SECRET_ACCESS_KEY = (New-Object System.Net.NetworkCredential('', $secretSecure)).Password
    $tokenSecure = Read-Host 'AWS Session Token (entrada oculta)' -AsSecureString
    $env:AWS_SESSION_TOKEN = (New-Object System.Net.NetworkCredential('', $tokenSecure)).Password
    $env:AWS_DEFAULT_REGION = $region
    $promptedForCredentials = $true
    $accountId = Get-AwsAccountId
}

if ($accountId -ne $expectedAccount) {
    throw "La identidad AWS corresponde a la cuenta '$accountId'; se esperaba '$expectedAccount'. No abrire el tunel."
}
Write-Host "Identidad AWS correcta: cuenta $accountId, region $region."

$instanceJson = & aws ec2 describe-instances `
    --filters "Name=tag:Name,Values=$instanceName" 'Name=instance-state-name,Values=running' `
    --query 'Reservations[].Instances[]' --output json --region $region
if ($LASTEXITCODE -ne 0) { throw 'No pude consultar la instancia K3s en EC2.' }
$instances = @($instanceJson | ConvertFrom-Json)
if ($instances.Count -ne 1) {
    throw "Esperaba una instancia K3s activa llamada '$instanceName'; encontre $($instances.Count). Revisa el laboratorio y la region."
}
$instance = $instances[0]
if ([string]::IsNullOrWhiteSpace($remoteHost)) { $remoteHost = $instance.PrivateDnsName }
if ([string]::IsNullOrWhiteSpace($remoteHost)) { $remoteHost = $instance.PrivateIpAddress }
Write-Host "Instancia SSM: $($instance.InstanceId)"
Write-Host "Destino remoto: ${remoteHost}:$remotePort; puerto local: $localPort"

if (Get-NetTCPConnection -LocalPort $localPort -State Listen -ErrorAction SilentlyContinue) {
    throw "El puerto local $localPort ya esta ocupado. Cierra el tunel anterior o libera ese puerto."
}

$requestPath = Join-Path $env:TEMP ("vibe-kubeconfig-{0}.json" -f [guid]::NewGuid().ToString('N'))
$request = @{
    DocumentName = 'AWS-RunShellScript'
    InstanceIds = @($instance.InstanceId)
    Parameters = @{ commands = @('sudo cat /etc/rancher/k3s/k3s.yaml') }
    TimeoutSeconds = 30
}
$request | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $requestPath -Encoding Ascii
try {
    $commandId = & aws ssm send-command `
        --cli-input-json "file://$requestPath" `
        --region $region --query Command.CommandId --output text
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($commandId)) {
        throw 'No pude solicitar el kubeconfig por SSM.'
    }
} finally {
    Remove-Item -LiteralPath $requestPath -Force -ErrorAction SilentlyContinue
}

$deadline = (Get-Date).AddMinutes(2)
do {
    Start-Sleep -Seconds 2
    $invocationJson = & aws ssm get-command-invocation `
        --command-id $commandId --instance-id $instance.InstanceId `
        --region $region --output json 2>$null
    if ($LASTEXITCODE -eq 0) { $invocation = $invocationJson | ConvertFrom-Json }
    if ((Get-Date) -gt $deadline) { throw 'SSM tardo mas de 2 minutos en devolver el kubeconfig.' }
} while (-not $invocation -or $invocation.Status -in @('Pending', 'InProgress', 'Delayed'))

if ($invocation.Status -ne 'Success') {
    if ($invocation.StandardErrorContent) { Write-Host $invocation.StandardErrorContent -ForegroundColor Red }
    throw "SSM no pudo leer el kubeconfig (estado: $($invocation.Status))."
}

$yaml = [string]$invocation.StandardOutputContent
$serverPattern = '(?m)^([ \t]*server:[ \t]*)https://127\.0\.0\.1:6443[ \t]*$'
if ($yaml -notmatch $serverPattern) {
    throw 'El kubeconfig remoto no tiene el endpoint K3s esperado (https://127.0.0.1:6443).'
}
$yaml = [regex]::Replace($yaml, $serverPattern, ('$1https://127.0.0.1:{0}' -f $localPort))

$kubeDir = Join-Path $env:USERPROFILE '.kube'
New-Item -ItemType Directory -Force -Path $kubeDir | Out-Null
$kubeFile = Join-Path $kubeDir 'config-vibe-aws.yaml'
$yaml | Set-Content -LiteralPath $kubeFile -Encoding Ascii
& icacls.exe $kubeFile /inheritance:r /grant:r "$($env:USERNAME):(R,W)" | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'No pude restringir los permisos del kubeconfig local.' }

Write-Host ''
Write-Host "Kubeconfig guardado en: $kubeFile" -ForegroundColor Green
Write-Host 'Manten esta ventana abierta. En otra ventana de PowerShell, ejecuta:' -ForegroundColor Yellow
Write-Host "`$env:KUBECONFIG = '$kubeFile'"
Write-Host 'kubectl get nodes -o wide'
Write-Host 'Set-Location "C:\Users\Michael\Universidad\Cloud Computing\vibe_k8s\k8s-web"'
Write-Host '& "C:\Users\Michael\AppData\Local\Python\bin\python.exe" server.py --ns vibe'
Write-Host ''
Write-Host 'El kubeconfig tiene acceso administrativo al cluster. No lo compartas ni lo subas al repositorio.' -ForegroundColor Yellow

try {
    & aws ssm start-session `
        --target $instance.InstanceId `
        --document-name AWS-StartPortForwardingSessionToRemoteHost `
        --parameters "host=$remoteHost,portNumber=$remotePort,localPortNumber=$localPort" `
        --region $region
    if ($LASTEXITCODE -ne 0) { throw 'La sesion de port forwarding SSM termino con error.' }
} finally {
    if ($promptedForCredentials) {
        Remove-Item Env:\AWS_ACCESS_KEY_ID, Env:\AWS_SECRET_ACCESS_KEY, Env:\AWS_SESSION_TOKEN, Env:\AWS_DEFAULT_REGION -ErrorAction SilentlyContinue
    }
}
