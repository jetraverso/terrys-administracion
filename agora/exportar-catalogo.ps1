# Terry's - exporta los productos de Agora para que Claude los revise (SOLO LECTURA).
#
# Le pide a la API local de Agora los datos maestros (productos, familias, tarifas, centros
# de venta, ordenes y tipos de preparacion) y los deja en la carpeta "exploracion", al lado
# de este archivo. No crea, no modifica ni borra nada en Agora: solo hace consultas GET.
# El token NO se guarda en los archivos.
#
# Uso: doble clic en "Exportar productos de Agora.cmd" (misma carpeta), o
#   powershell -ExecutionPolicy Bypass -File .\exportar-catalogo.ps1

$ErrorActionPreference = 'Stop'
$carpeta = Split-Path -Parent $MyInvocation.MyCommand.Path
# config.json: al lado del script o, si se corre desde el Drive, en Documents\Terrys Admin (no viaja por el Drive)
$rutaConfig = Join-Path $carpeta 'config.json'
if (-not (Test-Path $rutaConfig)) { $rutaConfig = Join-Path $env:USERPROFILE 'Documents\Terrys Admin\config.json' }
$cfg = Get-Content $rutaConfig -Raw -Encoding UTF8 | ConvertFrom-Json
$base = ([uri]$cfg.agoraExport).GetLeftPart([UriPartial]::Authority)   # p. ej. http://localhost:8984
$salida = Join-Path $carpeta 'exploracion'
New-Item -ItemType Directory -Force -Path $salida | Out-Null
$resumen = Join-Path $salida 'exportado.txt'
$lineas = @("Productos de Agora exportados el $(Get-Date -Format 'yyyy-MM-dd HH:mm')", "Base: $base", '')
$errores = 0

foreach ($f in 'Products', 'Families', 'PriceLists', 'SaleCenters', 'PreparationOrders', 'PreparationTypes') {
  $url = "$base/api/export-master/?filter=$f"
  $archivo = Join-Path $salida "maestro-$f.txt"
  try {
    $r = Invoke-WebRequest -Uri $url -Method Get -Headers @{ 'Api-Token' = $cfg.agoraToken } -UseBasicParsing -TimeoutSec 120
    [IO.File]::WriteAllText($archivo, $r.Content, [Text.Encoding]::UTF8)
    $linea = "OK     $f  ($([math]::Round($r.Content.Length/1KB,1)) KB)"
  } catch {
    $errores++
    $linea = "ERROR  $f  $($_.Exception.Message -replace '\s+', ' ')"
  }
  Write-Host $linea
  $lineas += $linea
}
$lineas | Set-Content $resumen -Encoding UTF8

Write-Host ''
if ($errores) {
  Write-Host "Hubo $errores error(es). Revisa que Agora este abierto en este equipo y avisale a Claude lo que dice arriba." -ForegroundColor Yellow
} else {
  Write-Host 'Listo. Google Drive lo sube solo en un minuto: ya podes avisarle a Claude.' -ForegroundColor Green
}
