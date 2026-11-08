[CmdletBinding()]
param(
    [string]$Region = $(if ($env:AWS_DEFAULT_REGION) { $env:AWS_DEFAULT_REGION } else { 'us-east-1' }),
    [string]$InstanceName = $(if ($env:VIBE_K3S_SERVER_TAG) { $env:VIBE_K3S_SERVER_TAG } else { 'vibe-desarrollo-k3s-server' }),
    [string]$ExpectedAccountId = $env:VIBE_AWS_ACCOUNT_ID,
    [string]$RemoteHost = '',
    [int]$RemotePort = 6443,
    [int]$LocalPort = 16443,
    [int]$AppPort = 8085
)

$ErrorActionPreference = 'Stop'
$promptedForCredentials = $false
$oldCredentialEnvironment = @{}
$sessionProcess = $null
$appProcess = $null
$failureMessage = $null
$oldKubeConfig = [Environment]::GetEnvironmentVariable('KUBECONFIG', 'Process')
$appStdout = Join-Path $env:TEMP 'vibe-k8s-web.out.log'
$appStderr = Join-Path $env:TEMP 'vibe-k8s-web.err.log'

function Get-AwsAccountId {
    try {
        $result = & aws sts get-caller-identity --query Account --output text --region $Region 2>$null
        if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace("$result")) { return $null }
        return "$result".Trim()
    } catch { return $null }
}

function Quote-ProcessArgument([string]$Value) {
    if ($Value -match '[\s"]') { return '"' + $Value.Replace('"', '\"') + '"' }
    return $Value
}

function Test-PortListening([int]$Port) {
    try {
        return [bool](Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction Stop | Select-Object -First 1)
    } catch { return $false }
}

try {
    $aws = Get-Command aws.exe -ErrorAction SilentlyContinue
    if (-not $aws) { $aws = Get-Command aws -ErrorAction SilentlyContinue }
    if (-not $aws) { throw 'No encuentro AWS CLI. Instala AWS CLI v2 y Session Manager plugin en esta PC.' }
    if (-not (Get-Command kubectl.exe -ErrorAction SilentlyContinue) -and -not (Get-Command kubectl -ErrorAction SilentlyContinue)) {
        throw 'No encuentro kubectl. Instala kubectl en esta PC y agregalo al PATH.'
    }

    Write-Host 'Conexion SSM al API de Kubernetes de VIBE' -ForegroundColor Cyan
    if ($RemoteHost -and ($RemoteHost -match '^https?://' -or $RemoteHost.Contains('/') -or $RemoteHost.Contains(':'))) {
        throw 'RemoteHost debe ser solo el DNS privado o IP privada, no el URL del ELB. Deja el valor vacio para autodetectar.'
    }
    if ($RemotePort -lt 1 -or $RemotePort -gt 65535) {
        throw 'El puerto debe ser un numero entre 1 y 65535.'
    }

    $accountId = Get-AwsAccountId
    if (-not $accountId) {
        Write-Host 'Introduce las credenciales temporales de AWS Academy (AWS Details > AWS CLI > Show). Se usan en esta ventana y no se guardan.' -ForegroundColor Yellow
        foreach ($name in @('AWS_ACCESS_KEY_ID', 'AWS_SECRET_ACCESS_KEY', 'AWS_SESSION_TOKEN', 'AWS_DEFAULT_REGION')) {
            $oldCredentialEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
        }
        $env:AWS_ACCESS_KEY_ID = Read-Host 'AWS Access Key ID'
        $secretSecure = Read-Host 'AWS Secret Access Key (entrada oculta)' -AsSecureString
        $env:AWS_SECRET_ACCESS_KEY = (New-Object System.Net.NetworkCredential('', $secretSecure)).Password
        $tokenSecure = Read-Host 'AWS Session Token (entrada oculta)' -AsSecureString
        $env:AWS_SESSION_TOKEN = (New-Object System.Net.NetworkCredential('', $tokenSecure)).Password
        $env:AWS_DEFAULT_REGION = $Region
        $promptedForCredentials = $true
        $accountId = Get-AwsAccountId
    }
    if (-not $accountId) { throw 'AWS no acepto las credenciales. Verifica que el laboratorio siga activo y que copiaste los tres valores de AWS CLI.' }
    if ($ExpectedAccountId -and $accountId -ne $ExpectedAccountId) {
        throw "La identidad corresponde a la cuenta '$accountId'; se esperaba '$ExpectedAccountId'. Revisa VIBE_AWS_ACCOUNT_ID."
    }
    Write-Host "Identidad AWS: cuenta $accountId, region $Region."

    $instanceJson = & aws ec2 describe-instances `
        --filters "Name=tag:Name,Values=$InstanceName" 'Name=instance-state-name,Values=running' `
        --query 'Reservations[].Instances[]' --output json --region $Region
    if ($LASTEXITCODE -ne 0) { throw 'No pude consultar EC2. Revisa permisos y que las credenciales no hayan expirado.' }
    $instances = @($instanceJson | ConvertFrom-Json)
    if ($instances.Count -ne 1) { throw "Se esperaba una instancia activa llamada '$InstanceName'; se encontraron $($instances.Count). Revisa Region y el estado del despliegue." }
    $instance = $instances[0]
    if ([string]::IsNullOrWhiteSpace($RemoteHost)) {
        $RemoteHost = if ($instance.PrivateDnsName) { $instance.PrivateDnsName } else { $instance.PrivateIpAddress }
    }
    if (Test-PortListening $LocalPort) { throw "El puerto local $LocalPort ya esta ocupado. Cierra el tunel anterior o define otro con -LocalPort." }
    if (Test-PortListening $AppPort) { throw "El puerto local de k8s-web $AppPort ya esta ocupado. Cierra la aplicacion anterior o define otro con -AppPort." }

    Write-Host "Instancia: $($instance.InstanceId); destino remoto: ${RemoteHost}:$RemotePort; puerto local: $LocalPort"

    $requestPath = Join-Path $env:TEMP ("vibe-kubeconfig-{0}.json" -f [guid]::NewGuid().ToString('N'))
    $request = @{
        DocumentName = 'AWS-RunShellScript'
        InstanceIds = @($instance.InstanceId)
        Parameters = @{ commands = @('sudo cat /etc/rancher/k3s/k3s.yaml') }
        TimeoutSeconds = 30
    }
    $request | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $requestPath -Encoding Ascii
    try {
        $commandId = & aws ssm send-command --cli-input-json "file://$requestPath" --region $Region --query Command.CommandId --output text
        if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($commandId)) { throw 'No pude solicitar el kubeconfig por SSM.' }
    } finally { Remove-Item -LiteralPath $requestPath -Force -ErrorAction SilentlyContinue }

    $deadline = (Get-Date).AddMinutes(2)
    $invocation = $null
    do {
        Start-Sleep -Seconds 2
        $invocationJson = & aws ssm get-command-invocation --command-id $commandId --instance-id $instance.InstanceId --region $Region --output json 2>$null
        if ($LASTEXITCODE -eq 0) { $invocation = $invocationJson | ConvertFrom-Json }
        if ((Get-Date) -gt $deadline) { throw 'SSM tardo mas de 2 minutos en devolver el kubeconfig.' }
    } while (-not $invocation -or $invocation.Status -in @('Pending', 'InProgress', 'Delayed'))
    if ($invocation.Status -ne 'Success') { throw "SSM no pudo leer el kubeconfig (estado: $($invocation.Status)). $($invocation.StandardErrorContent)" }

    $yaml = [string]$invocation.StandardOutputContent
    $serverPattern = '(?m)^([ \t]*server:[ \t]*)https://127\.0\.0\.1:6443[ \t]*$'
    if ($yaml -notmatch $serverPattern) { throw 'El kubeconfig recibido no tiene el endpoint K3s esperado.' }
    $yaml = [regex]::Replace($yaml, $serverPattern, ('$1https://127.0.0.1:{0}' -f $LocalPort))
    $kubeDir = Join-Path $env:USERPROFILE '.kube'
    New-Item -ItemType Directory -Force -Path $kubeDir | Out-Null
    $kubeFile = Join-Path $kubeDir 'config-vibe-aws.yaml'
    $yaml | Set-Content -LiteralPath $kubeFile -Encoding Ascii
    & icacls.exe $kubeFile /inheritance:r /grant:r "$($env:USERNAME):(R,W)" | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'No pude restringir los permisos del kubeconfig local.' }

    $python = Get-Command python.exe -ErrorAction SilentlyContinue
    $pythonPrefix = @()
    if (-not $python) {
        $python = Get-Command py.exe -ErrorAction SilentlyContinue
        if ($python) { $pythonPrefix = @('-3') }
    }
    if (-not $python) { throw 'No encuentro Python. Instala Python 3.9 o superior en esta PC.' }
    $serverPath = Join-Path $PSScriptRoot 'server.py'
    if (-not (Test-Path -LiteralPath $serverPath)) { throw "No encuentro server.py junto al script: $serverPath" }

    $awsArgs = @('ssm', 'start-session', '--target', $instance.InstanceId,
        '--document-name', 'AWS-StartPortForwardingSessionToRemoteHost',
        '--parameters', "host=$RemoteHost,portNumber=$RemotePort,localPortNumber=$LocalPort", '--region', $Region)
    $quotedAwsArgs = ($awsArgs | ForEach-Object { Quote-ProcessArgument $_ }) -join ' '
    $sessionProcess = Start-Process -FilePath $aws.Source -ArgumentList $quotedAwsArgs -PassThru -NoNewWindow

    $tunnelDeadline = (Get-Date).AddSeconds(60)
    while (-not (Test-PortListening $LocalPort)) {
        if ($sessionProcess.HasExited) { throw 'La sesion SSM termino antes de abrir el puerto. Revisa el mensaje de AWS CLI y el Session Manager plugin.' }
        if ((Get-Date) -gt $tunnelDeadline) { throw 'El tunel SSM no abrio el puerto local en 60 segundos.' }
        Start-Sleep -Milliseconds 500
    }

    $env:KUBECONFIG = $kubeFile
    $check = & kubectl get nodes --request-timeout=15s 2>&1
    if ($LASTEXITCODE -ne 0) { throw "El cluster no responde por kubectl: $check" }

    $pythonArgumentValues = @()
    $pythonArgumentValues += $pythonPrefix
    $pythonArgumentValues += @($serverPath, '--ns', 'vibe', '--port', "$AppPort")
    $pythonArgs = ($pythonArgumentValues | ForEach-Object { Quote-ProcessArgument "$_" }) -join ' '
    $appProcess = Start-Process -FilePath $python.Source -ArgumentList $pythonArgs -WorkingDirectory $PSScriptRoot -PassThru -WindowStyle Hidden -RedirectStandardOutput $appStdout -RedirectStandardError $appStderr
    Start-Sleep -Seconds 2
    if ($appProcess.HasExited) { throw "k8s-web no pudo iniciar. Revisa $appStderr" }

    $appUrl = "http://127.0.0.1:$AppPort"
    Write-Host "Tunel activo. k8s-web esta disponible en $appUrl" -ForegroundColor Green
    Write-Host 'Deja esta ventana abierta. Al cerrarla, se cerraran el tunel y k8s-web.' -ForegroundColor Yellow
    Start-Process $appUrl
    while (-not $sessionProcess.HasExited) { Start-Sleep -Seconds 1 }
    if ($sessionProcess.ExitCode -ne 0) { throw 'La sesion de port forwarding SSM termino con error.' }
} catch {
    Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
    $failureMessage = $_.Exception.Message
} finally {
    if ($appProcess -and -not $appProcess.HasExited) { Stop-Process -Id $appProcess.Id -Force -ErrorAction SilentlyContinue }
    if ($sessionProcess -and -not $sessionProcess.HasExited) { Stop-Process -Id $sessionProcess.Id -Force -ErrorAction SilentlyContinue }
    [Environment]::SetEnvironmentVariable('KUBECONFIG', $oldKubeConfig, 'Process')
    if ($promptedForCredentials) {
        foreach ($name in $oldCredentialEnvironment.Keys) {
            [Environment]::SetEnvironmentVariable($name, $oldCredentialEnvironment[$name], 'Process')
        }
    }
}
if ($failureMessage) { exit 1 }
