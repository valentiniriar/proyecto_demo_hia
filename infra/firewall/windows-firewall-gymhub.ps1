<#
.SYNOPSIS
  Reglas de Firewall de Windows para el host que corre GymHub (SCRUM-61).

.DESCRIPTION
  GymHub se publica SOLO por Cloudflare Tunnel, que usa conexiones salientes.
  Por eso no hace falta ninguna regla de entrada que permita tráfico: el script
  BLOQUEA la entrada desde la red (LAN o Internet) a los puertos de la app y de
  las herramientas internas, como defensa en profundidad por si alguien publica
  un puerto en 0.0.0.0 por error (ej. GYMHUB_BIND=0.0.0.0).

  El acceso desde la propia PC (localhost) no pasa por el firewall y sigue funcionando.

  Ejecutar en PowerShell COMO ADMINISTRADOR:
    .\infra\firewall\windows-firewall-gymhub.ps1            # crea / actualiza las reglas
    .\infra\firewall\windows-firewall-gymhub.ps1 -Listar    # muestra las reglas actuales
    .\infra\firewall\windows-firewall-gymhub.ps1 -Quitar    # elimina las reglas
#>
[CmdletBinding()]
param(
    [switch]$Quitar,
    [switch]$Listar
)

$Grupo = 'GymHub (SCRUM-61)'

# Puerto -> descripción. Ninguno debe ser accesible desde otra máquina.
$Puertos = [ordered]@{
    3000 = 'API backend (solo vía Nginx/túnel)'
    8080 = 'Frontend Nginx (solo vía túnel)'
    5432 = 'PostgreSQL (servicio local de Windows u otro)'
    5433 = 'PostgreSQL GymHub (primario)'
    5434 = 'PostgreSQL GymHub (réplica)'
    5050 = 'pgAdmin'
    9090 = 'Prometheus'
    9093 = 'Alertmanager'
    3001 = 'Grafana'
    5678 = 'n8n'
    5679 = 'n8n (puerto host)'
    8990 = 'Mantis Bug Tracker'
    2000 = 'Métricas de cloudflared'
}

if ($Listar) {
    Get-NetFirewallRule -Group $Grupo -ErrorAction SilentlyContinue |
        ForEach-Object {
            $f = $_ | Get-NetFirewallPortFilter
            [pscustomobject]@{ Regla = $_.DisplayName; Accion = $_.Action; Direccion = $_.Direction; Puerto = $f.LocalPort; Habilitada = $_.Enabled }
        } | Format-Table -AutoSize
    return
}

$esAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $esAdmin) { throw 'Ejecutar PowerShell como Administrador.' }

# Idempotente: siempre se borran las reglas del grupo antes de crearlas.
Get-NetFirewallRule -Group $Grupo -ErrorAction SilentlyContinue | Remove-NetFirewallRule
if ($Quitar) { Write-Host "Reglas del grupo '$Grupo' eliminadas."; return }

foreach ($p in $Puertos.Keys) {
    New-NetFirewallRule -Group $Grupo `
        -DisplayName "GymHub - bloquear entrada TCP $p ($($Puertos[$p]))" `
        -Direction Inbound -Action Block -Protocol TCP -LocalPort $p `
        -RemoteAddress Any -Profile Any | Out-Null
}

Write-Host "Creadas $($Puertos.Count) reglas de bloqueo de entrada en el grupo '$Grupo'."
Write-Host 'No se crean reglas de permiso: el túnel de Cloudflare solo usa tráfico saliente (TCP/UDP 7844).'
& $PSCommandPath -Listar
