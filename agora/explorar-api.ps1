# Terry's - explora la API de integracion de Agora (SOLO LECTURA).
#
# Le pide a la API local de Agora los datos maestros (productos, centros de venta,
# formas de pago, series, pedidos...) y busca si trae ayuda/documentacion. No crea,
# no modifica ni borra nada en Agora: solo hace consultas GET.
#
# Corre en la computadora del TPV, en la misma carpeta que subir-ventas.ps1
# (usa el mismo config.json). Uso:
#   powershell -ExecutionPolicy Bypass -File .\explorar-api.ps1
#
# Deja todo en la carpeta "exploracion" y un resumen en exploracion\resumen.txt.
# Despues comprimi esa carpeta y pasasela a Claude. El token NO se guarda en los archivos.

$ErrorActionPreference = 'Stop'
$carpeta = Split-Path -Parent $MyInvocation.MyCommand.Path
# config.json: al lado del script o, si se corre desde el Drive, en Documents\Terrys Admin (no viaja por el Drive)
$rutaConfig = Join-Path $carpeta 'config.json'
if (-not (Test-Path $rutaConfig)) { $rutaConfig = Join-Path $env:USERPROFILE 'Documents\Terrys Admin\config.json' }
$cfg = Get-Content $rutaConfig -Raw -Encoding UTF8 | ConvertFrom-Json
$base = ([uri]$cfg.agoraExport).GetLeftPart([UriPartial]::Authority)   # p. ej. http://localhost:8984
$salida = Join-Path $carpeta 'exploracion'
New-Item -ItemType Directory -Force -Path $salida | Out-Null
$resumen = Join-Path $salida 'resumen.txt'
"Exploracion de la API de Agora - $(Get-Date -Format 'yyyy-MM-dd HH:mm')`r`nBase: $base`r`n" | Set-Content $resumen -Encoding UTF8

$hoy = (Get-Date).ToString('yyyy-MM-dd')
$ayer = (Get-Date).AddDays(-1).ToString('yyyy-MM-dd')

# Datos maestros que suele exportar Agora (los que no existan devuelven error y se anotan).
$filtros = 'Products','Families','SaleFormats','PreparationTypes','PreparationOrders','SaleCenters',
           'PaymentMethods','Series','Pos','Users','PriceLists','Vats','MenuGroups','Offers'
$consultas = @()
foreach ($f in $filtros) { $consultas += @{ nombre = "maestro-$f"; url = "$base/api/export-master/?filter=$f" } }
foreach ($f in $filtros) { $consultas += @{ nombre = "export-$f";  url = "$base/api/export/?filter=$f" } }
# Documentos del dia: pedidos, tickets abiertos, albaranes (para ver como es un pedido take away por dentro).
foreach ($f in 'SalesOrders','Orders','DeliveryNotes','Tickets','OpenTickets','Invoices') {
  $consultas += @{ nombre = "dia-$f-hoy";  url = "$base/api/export/?filter=$f&business-day=$hoy" }
  $consultas += @{ nombre = "dia-$f-ayer"; url = "$base/api/export/?filter=$f&business-day=$ayer" }
}
# Trae ayuda o documentacion?
foreach ($p in '/', '/api', '/api/', '/api/help', '/help', '/doc', '/docs', '/swagger', '/swagger/ui/index', '/api/doc', '/api/import', '/api/import/') {
  $consultas += @{ nombre = "ayuda" + ($p -replace '[^a-zA-Z0-9]', '_'); url = "$base$p" }
}

foreach ($c in $consultas) {
  $archivo = Join-Path $salida ($c.nombre + '.txt')
  try {
    $r = Invoke-WebRequest -Uri $c.url -Method Get -Headers @{ 'Api-Token' = $cfg.agoraToken } -UseBasicParsing -TimeoutSec 60
    [IO.File]::WriteAllText($archivo, $r.Content, [Text.Encoding]::UTF8)
    $linea = "OK     $($r.StatusCode)  $($c.url)  ($([math]::Round($r.Content.Length/1KB,1)) KB)"
  } catch {
    $codigo = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { '---' }
    $cuerpo = ''
    if ($_.ErrorDetails -and $_.ErrorDetails.Message) { $cuerpo = $_.ErrorDetails.Message }   # PowerShell 5.1 deja aca el texto del error
    if (-not $cuerpo) { try { $st = $_.Exception.Response.GetResponseStream(); if ($st.CanSeek) { $st.Position = 0 }; $cuerpo = (New-Object IO.StreamReader($st)).ReadToEnd() } catch {} }
    if ($cuerpo) { [IO.File]::WriteAllText($archivo, $cuerpo, [Text.Encoding]::UTF8) }
    $linea = "ERROR  $codigo  $($c.url)  $($_.Exception.Message -replace '\s+', ' ')"
  }
  Write-Host $linea
  Add-Content $resumen $linea -Encoding UTF8
}

# Documentacion que pueda haber dejado el instalador de Agora.
Add-Content $resumen "`r`nArchivos de documentacion en la instalacion de Agora:" -Encoding UTF8
foreach ($dir in "${env:ProgramFiles(x86)}\IGT Microelectronics", "$env:ProgramFiles\IGT Microelectronics", "${env:ProgramFiles(x86)}\Agora", "$env:ProgramFiles\Agora") {
  if (Test-Path $dir) {
    Get-ChildItem $dir -Recurse -ErrorAction SilentlyContinue -Include *.pdf,*.chm,*.html,*.md,*.txt,*.json,*.xml |
      Where-Object { $_.FullName -match 'api|integra|import|doc|help|ayuda|custom-queries' } |
      Select-Object -First 200 | ForEach-Object { Add-Content $resumen $_.FullName -Encoding UTF8 }
  }
}

Write-Host "`r`nListo. Comprimi la carpeta '$salida' y pasasela a Claude." -ForegroundColor Green
