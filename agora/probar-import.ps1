# Terry's - prueba el endpoint de importacion de Agora SIN cargar nada.
#
# Le manda a /api/import/ pedidos VACIOS o incompletos para leer los mensajes de
# error, que suelen decir que formato espera. Ninguna de estas pruebas tiene
# productos, asi que no puede crear un pedido ni un ticket.
#
# Corre en la carpeta de subir-ventas.ps1 (usa el mismo config.json):
#   powershell -ExecutionPolicy Bypass -File .\probar-import.ps1
# Deja todo en exploracion\import-*.txt y en exploracion\import-resumen.txt.

$ErrorActionPreference = 'Stop'
$carpeta = Split-Path -Parent $MyInvocation.MyCommand.Path
# config.json: al lado del script o, si se corre desde el Drive, en Documents\Terrys Admin (no viaja por el Drive)
$rutaConfig = Join-Path $carpeta 'config.json'
if (-not (Test-Path $rutaConfig)) { $rutaConfig = Join-Path $env:USERPROFILE 'Documents\Terrys Admin\config.json' }
$cfg = Get-Content $rutaConfig -Raw -Encoding UTF8 | ConvertFrom-Json
$base = ([uri]$cfg.agoraExport).GetLeftPart([UriPartial]::Authority)
$salida = Join-Path $carpeta 'exploracion'
New-Item -ItemType Directory -Force -Path $salida | Out-Null
$resumen = Join-Path $salida 'import-resumen.txt'
"Pruebas de /api/import - $(Get-Date -Format 'yyyy-MM-dd HH:mm')" | Set-Content $resumen -Encoding UTF8

$pruebas = @(
  @{ n = '01-vacio';             b = '{}' },
  @{ n = '02-salesorders-vacio'; b = '{"SalesOrders":[]}' },
  @{ n = '03-invoices-vacio';    b = '{"Invoices":[]}' },
  @{ n = '04-orders-vacio';      b = '{"Orders":[]}' },
  @{ n = '05-salesorder-sin-lineas'; b = '{"SalesOrders":[{"Serie":"ZZPRUEBA","Lines":[]}]}' },
  @{ n = '06-texto';             b = 'hola' }
)
$urls = @("$base/api/import/", "$base/api/import/?filter=SalesOrders")

foreach ($u in $urls) {
  foreach ($p in $pruebas) {
    $nombre = 'import-' + $p.n + $(if ($u -match 'filter') { '-filter' } else { '' })
    $archivo = Join-Path $salida ($nombre + '.txt')
    try {
      $r = Invoke-WebRequest -Uri $u -Method Post -Body ([Text.Encoding]::UTF8.GetBytes($p.b)) `
           -ContentType 'application/json; charset=utf-8' -Headers @{ 'Api-Token' = $cfg.agoraToken } -UseBasicParsing -TimeoutSec 60
      [IO.File]::WriteAllText($archivo, "BODY ENVIADO: $($p.b)`r`n`r`n$($r.Content)", [Text.Encoding]::UTF8)
      $linea = "OK     $($r.StatusCode)  $u  $($p.n)  ->  $($r.Content -replace '\s+', ' ')"
    } catch {
      $codigo = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { '---' }
      $cuerpo = ''
      if ($_.ErrorDetails -and $_.ErrorDetails.Message) { $cuerpo = $_.ErrorDetails.Message }   # PowerShell 5.1 deja aca el texto del error
    if (-not $cuerpo) { try { $st = $_.Exception.Response.GetResponseStream(); if ($st.CanSeek) { $st.Position = 0 }; $cuerpo = (New-Object IO.StreamReader($st)).ReadToEnd() } catch {} }
      [IO.File]::WriteAllText($archivo, "BODY ENVIADO: $($p.b)`r`n`r`n$cuerpo", [Text.Encoding]::UTF8)
      $linea = "ERROR  $codigo  $u  $($p.n)  ->  $($cuerpo -replace '\s+', ' ')"
    }
    if ($linea.Length -gt 400) { $linea = $linea.Substring(0, 400) + '...' }
    Write-Host $linea
    Add-Content $resumen $linea -Encoding UTF8
  }
}
Write-Host "`r`nListo. Pasale a Claude lo que salio en pantalla (o el archivo exploracion\import-resumen.txt)." -ForegroundColor Green
