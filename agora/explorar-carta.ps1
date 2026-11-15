# Terry's - lee como arma Agora la carta de cada centro de venta (botones del iPad). SOLO LECTURA.
#
#   powershell -ExecutionPolicy Bypass -File "G:\Mi unidad\Terry Admin AI\Sistema Pedidos\explorar-carta.ps1"
#
# Guarda en exploracion-mesas\carta-*.csv las tablas de categorias, centros y mesas de la base
# de Agora (sin clientes ni ventas) y prueba el filtro Categories de la API. Solo hace SELECT y GET.

$ErrorActionPreference = 'Continue'
$carpeta = Split-Path -Parent $MyInvocation.MyCommand.Path
$rutaConfig = Join-Path $carpeta 'config.json'
if (-not (Test-Path $rutaConfig)) { $rutaConfig = Join-Path $env:USERPROFILE 'Documents\Terrys Admin\config.json' }
$cfg = Get-Content $rutaConfig -Raw -Encoding UTF8 | ConvertFrom-Json
$base = ([uri]$cfg.agoraExport).GetLeftPart([UriPartial]::Authority)
$salida = Join-Path $carpeta 'exploracion-mesas'
New-Item -ItemType Directory -Force -Path $salida | Out-Null
$resumen = Join-Path $salida 'carta-resumen.txt'
"Carta por centro de venta - $(Get-Date -Format 'yyyy-MM-dd HH:mm')" | Set-Content $resumen -Encoding UTF8
function Anotar($t, $color = 'Gray') { Write-Host $t -ForegroundColor $color; Add-Content $resumen $t -Encoding UTF8 }

foreach ($f in 'Categories', 'ProductCategories', 'MenuGroups') {
  try {
    $r = Invoke-WebRequest -Uri "$base/api/export-master/?filter=$f" -Headers @{ 'Api-Token' = $cfg.agoraToken } -UseBasicParsing -TimeoutSec 60
    $r.Content | Set-Content (Join-Path $salida "carta-api-$f.json") -Encoding UTF8
    Anotar "API $f : OK ($($r.Content.Length) bytes)" 'Green'
  } catch { Anotar "API $f : error" }
}

$cn = New-Object System.Data.SqlClient.SqlConnection 'Server=localhost\AGORA;Database=igtpos;Integrated Security=True;Connect Timeout=8;ApplicationIntent=ReadOnly'
try { $cn.Open() } catch { Anotar "No pude abrir la base: $($_.Exception.Message)" 'Red'; exit 1 }
foreach ($t in 'Category', 'CategorySaleCenters', 'ProductCategory', 'CategorySchedules', 'CategoryPosGroups', 'SaleCenter', 'SaleLocation',
               'Family', 'PosGroup', 'IndexedGroup', 'MajorGroup', 'DigitalMenuCategory', 'TimeFrameGroup', 'PriceList') {
  try {
    $cmd = $cn.CreateCommand(); $cmd.CommandText = "select * from dbo.[$t]"; $cmd.CommandTimeout = 30
    $tab = New-Object System.Data.DataTable; $tab.Load($cmd.ExecuteReader())
    # sin columnas de imagenes (binarios)
    $cols = @($tab.Columns | Where-Object { $_.DataType -ne [byte[]] } | ForEach-Object { $_.ColumnName })
    $tab | Select-Object $cols | Export-Csv (Join-Path $salida "carta-$t.csv") -NoTypeInformation -Encoding UTF8
    Anotar ("{0}: {1} filas - columnas: {2}" -f $t, $tab.Rows.Count, ($cols -join ', '))
  } catch { Anotar "$t : $($_.Exception.Message)" }
}
$cn.Close()
Anotar "`r`nListo. Avisale a Claude." 'Green'
