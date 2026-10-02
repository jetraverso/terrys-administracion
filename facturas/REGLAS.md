# Cómo se cargan las facturas de Drive en Finanzas

Lo sigue Claude, tanto a pedido en el chat como desde la tarea programada que atiende el botón "Actualizar facturas".

## Dónde están

Carpeta sincronizada en la Mac: `~/admin.terrys.ia@gmail.com - Google Drive/My Drive/Terry Admin AI/Proveedores/AAAA/MM_Mes/`.
Los archivos se llaman `MMDD_Proveedor_Detalle.pdf|jpg` (ej. `0918_Europastry_Reposicion panes.PDF`).

## Herramienta

`python3 facturas/facturas.py` desde la carpeta `administracion`:

- `listar 2026-10` → JSON con cada archivo, su id de Drive y `cargada` (`null` = pendiente; `{"descartada": true}` = alguien borró su fila: NO se vuelve a subir).
- `subir '{"ruta": "2026/10_Octubre/archivo.pdf", "fecha": "2026-10-01", "total": 138.59, "proveedor": "Europastry", "detalle": "Reposicion panes", "nota": "Factura 24015086 · vence 06/10 · giro"}'`
  - opcionales: `"ingreso": true` (plata que entra), `"tipo"`, `"desde"`, `"hacia"` para fijarlos.
  - responde `estado`: `vinculada` (ya estaba cargada a mano: solo se le puso el link), `nueva` (fila por revisar), `ya_cargada`, `descartada`.

## Qué dato va en cada campo

- **fecha** y **detalle**: del NOMBRE del archivo (`MMDD` → `AAAA-MM-DD` del año de la carpeta; `Detalle` tal cual), no de la fecha impresa: así coincide con cómo carga Juan.
- **proveedor**: el del nombre del archivo.
- **total**: el total a pagar CON IVA del documento (no la base imponible). En fotos, comprobar que base + IVA = total.
- **nota**: `Factura N · vence dd/mm · forma de pago` (o `Albarán N`, `Ticket N`). Si algo se lee mal o es dudoso, agregarlo a la nota ("foto borrosa: revisar el total").

## Qué NO se carga

- **Factura mensual de Ruibal Losada** (archivo tipo `004587M...pdf` que agrupa los albaranes del mes): no se sube. Sí se comprueba que la suma de los albaranes del mes dé lo mismo (±0,05 €) y se avisa si no.
- **Albaranes sin precio** (ej. Chef Click sin importes) y hojas manuscritas sin importe.
- **Liquidaciones de Glovo**: NO se carga el pago como ingreso (las ventas por Glovo ya entran con las ventas diarias de Ágora). Se carga SOLO la comisión de Glovo como egreso: `"proveedor": "Glovo"`, `"detalle": "Comision Glovo periodo ..."`, fecha = fecha del documento.
- **Albarán + factura del mismo envío** (pasa con Crusat: la factura dice "Nº alb. APxxxxx" y tiene el mismo importe que un albarán de días antes): es UN solo gasto. Si el albarán ya está cargado, no subir la factura: avisar del duplicado.

## Qué va como ingreso (`"ingreso": true`)

- **Abonos / devoluciones a favor** (ej. Discer devolución de envase, importe negativo): ingreso por el valor absoluto.
- **Hojas manuscritas de Harmonia** (recogida de aceite usado) cuando tienen importe: ingreso con `"tipo": "Ingresos", "desde": "Harmonia", "hacia": "CAIXA"`.

## Después de subir

Resumen para la persona: cuántas vinculadas, cuántas nuevas por revisar (con la lista y los importes), cuáles no se subieron y por qué, y cualquier duda (fotos borrosas, posibles duplicados, importes raros).
