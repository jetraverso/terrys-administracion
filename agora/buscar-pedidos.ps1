# Terry's - busca pedidos (SalesOrders) ya hechos en Agora, para copiar su formato. SOLO LECTURA.
#
# Recorre los ultimos dias (por defecto 180) pidiendo a la API los pedidos y albaranes
# de cada dia, y guarda los dias que tengan alguno en exploracion\pedidos-AAAA-MM-DD.txt.
#   powershell -ExecutionPolicy Bypass -File .\buscar-pedidos.ps1
#   powershell -ExecutionPolicy Bypass -File .\buscar-pedidos.ps1 -Dias 400

param([int]$Dias = 180)
$ErrorActionPreference = 'Stop'
$carpeta = Split-Path -Parent $MyInvocation.MyCommand.Path
# config.json: al lado del script o, si se corre desde el Drive, en Documents\Terrys Admin (no viaja por el Drive)
$rutaConfig = Join-Path $carpeta 'config.json'
if (-not (Test-Path $rutaConfig)) { $rutaConfig = Join-Path $env:USERPROFILE 'Documents\Terrys Admin\config.json' }
$cfg = Get-Content $rutaConfig -Raw -Encoding UTF8 | ConvertFrom-Json
$base = ([uri]$cfg.agoraExport).GetLeftPart([UriPartial]::Authority)
$salida = Join-Path $carpeta 'exploracion'
New-Item -ItemType Directory -Force -Path $salida | Out-Null
$encontrados = 0
Write-Host "buscar-pedidos v2 - revisando $Dias dias (las respuestas vacias {} no cuentan)"

for ($i = 0; $i -le $Dias; $i++) {
  $dia = (Get-Date).Date.AddDays(-$i).ToString('yyyy-MM-dd')
  foreach ($f in 'SalesOrders', 'DeliveryNotes') {
    try {
      $r = Invoke-WebRequest -Uri "$base/api/export/?filter=$f&business-day=$dia" -Headers @{ 'Api-Token' = $cfg.agoraToken } -UseBasicParsing -TimeoutSec 60
      $txt = ([string]$r.Content).Trim([char[]]@([char]0xFEFF, [char]32, [char]13, [char]10, [char]9))
      if ($txt.Length -gt 10) {
        $j = $txt | ConvertFrom-Json
        $n = if ($null -ne $j.$f) { @($j.$f | Where-Object { $_ }).Count } else { 0 }
        if ($n -gt 0) {
          [IO.File]::WriteAllText((Join-Path $salida "$f-$dia.txt"), $txt, [Text.Encoding]::UTF8)
          Write-Host "ENCONTRADO  $dia  $f  $n" -ForegroundColor Green
          $encontrados++
        }
      }
    } catch {
      Write-Host "ERROR  $dia  $f  $($_.Exception.Message)"
    }
  }
  if ($encontrados -ge 6) { break }
  if ($i % 15 -eq 0) { Write-Host "... revisado hasta $dia" }
}
Write-Host "`r`nListo: $encontrados dias con pedidos/albaranes. Pasale a Claude los archivos exploracion\SalesOrders-*.txt y DeliveryNotes-*.txt" -ForegroundColor Green
