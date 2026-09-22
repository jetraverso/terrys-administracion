# Terry's Administración — sube a Supabase las ventas diarias de Ágora POS.
#
# Corre en la computadora del TPV (Windows). Le pide a la API de Ágora las ventas
# de cada día y las manda a la función subir_ventas() de Supabase.
#
# Uso:
#   .\subir-ventas.ps1              sube los últimos 3 días (ayer y los dos anteriores; así se
#                                   rellena solo si algún día no se pudo subir)
#   .\subir-ventas.ps1 -Dias 30     sube los últimos 30 días
#   .\subir-ventas.ps1 -Desde 2026-07-01 -Hasta 2026-08-31   sube ese rango (carga inicial)
#   .\subir-ventas.ps1 -Hoy         sube también el día de hoy (parcial, lo que va hasta ahora)
#
# La configuración va en config.json, al lado de este archivo (copiá config.ejemplo.json).

param(
  [int]$Dias = 3,
  [string]$Desde,
  [string]$Hasta,
  [switch]$Hoy
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$carpeta = Split-Path -Parent $MyInvocation.MyCommand.Path
$log = Join-Path $carpeta 'subir-ventas.log'

function Escribir($texto) {
  $linea = "{0}  {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $texto
  Write-Host $linea
  Add-Content -Path $log -Value $linea -Encoding UTF8
}

# ---------- configuración ----------
$rutaConfig = Join-Path $carpeta 'config.json'
if (-not (Test-Path $rutaConfig)) {
  Write-Host "Falta config.json. Copiá config.ejemplo.json a config.json y completalo." -ForegroundColor Red
  exit 1
}
$cfg = Get-Content $rutaConfig -Raw -Encoding UTF8 | ConvertFrom-Json
foreach ($k in 'agoraExport', 'agoraToken', 'supabaseUrl', 'supabaseKey', 'integracionToken') {
  if (-not $cfg.$k) { Write-Host "En config.json falta '$k'." -ForegroundColor Red; exit 1 }
}
$empresa = if ($cfg.empresa) { $cfg.empresa } else { 'terrys-burgers-sl' }

# ---------- qué días subir ----------
$lista = @()
if ($Desde) {
  $d = [datetime]::ParseExact($Desde, 'yyyy-MM-dd', $null)
  $h = if ($Hasta) { [datetime]::ParseExact($Hasta, 'yyyy-MM-dd', $null) } else { (Get-Date).Date.AddDays(-1) }
  while ($d -le $h) { $lista += $d; $d = $d.AddDays(1) }
} else {
  for ($i = $Dias; $i -ge 1; $i--) { $lista += (Get-Date).Date.AddDays(-$i) }
}
if ($Hoy) { $lista += (Get-Date).Date }

# ---------- subida ----------
$ok = 0; $mal = 0
foreach ($dia in $lista) {
  $iso = $dia.ToString('yyyy-MM-dd')
  try {
    # 1) pedir el día a Ágora (texto crudo, en UTF-8, sin volver a serializar)
    $url = $cfg.agoraExport.Replace('{dia}', $iso)
    $wc = New-Object System.Net.WebClient
    $wc.Encoding = [System.Text.Encoding]::UTF8
    $wc.Headers['Api-Token'] = $cfg.agoraToken
    $json = $wc.DownloadString($url)
    if (-not $json -or $json.TrimStart()[0] -ne '{') { throw "Ágora no devolvió un JSON (respuesta: $($json.Substring(0, [Math]::Min(120, $json.Length))))" }

    # 2) mandarlo a Supabase
    $cuerpo = '{"p_token":' + (ConvertTo-Json $cfg.integracionToken) + ',"p_dia":"' + $iso + '","p_empresa":' + (ConvertTo-Json $empresa) + ',"p_datos":' + $json + '}'
    $wc2 = New-Object System.Net.WebClient
    $wc2.Encoding = [System.Text.Encoding]::UTF8
    $wc2.Headers['apikey'] = $cfg.supabaseKey
    $wc2.Headers['Authorization'] = 'Bearer ' + $cfg.supabaseKey
    $wc2.Headers['Content-Type'] = 'application/json'
    $resp = $wc2.UploadString(($cfg.supabaseUrl.TrimEnd('/') + '/rest/v1/rpc/subir_ventas'), 'POST', $cuerpo)
    $r = $resp | ConvertFrom-Json
    Escribir ("OK   {0}: {1} tickets ({2} KB)" -f $iso, $r.tickets, [Math]::Round($json.Length / 1024))
    $ok++
  } catch {
    $msg = $_.Exception.Message
    if ($_.Exception.Response) {
      try { $sr = New-Object IO.StreamReader($_.Exception.Response.GetResponseStream()); $msg += ' · ' + $sr.ReadToEnd() } catch {}
    }
    Escribir ("ERROR {0}: {1}" -f $iso, $msg)
    $mal++
  }
}
Escribir ("Fin: {0} días subidos, {1} con error." -f $ok, $mal)
if ($mal -gt 0) { exit 1 }
