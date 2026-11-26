# Detalle de las facturas para la solapa Stock

Además de cargar el total en Compras, de cada factura / albarán / ticket de **mercadería** se guarda el
detalle renglón por renglón (producto, cantidad, precio). Con eso la solapa Stock muestra qué se compra,
cuánto y a qué precio, y avisa cuando un precio cambia.

## Qué se escribe

Un archivo JSON por documento en `facturas/lineas/AAAA-MM/<nombre del archivo>.json` (carpeta local, no se sube al repo):

```json
{
  "ruta": "2026/11_Noviembre/1103_Europastry_Reposicion panes.PDF",
  "proveedor": "Europastry",
  "numero": "24122987",
  "documento": "factura",
  "base": 140.09,
  "total": 154.10,
  "lineas": [
    {"codigo": "85492", "descripcion": "Burger Brioche (60u)", "nombre": "Pan brioche burger (caja 60 u)",
     "categoria": "Pan", "cantidad": 6, "unidad": "caja", "precio": 23.349, "importe": 140.09, "iva": 10,
     "nota": "artículo en promoción"}
  ],
  "dudas": ""
}
```

- **ruta**: la del listado (`AAAA/MM_Mes/archivo`), tal cual.
- **proveedor**: siempre el mismo nombre para el mismo proveedor (no copiar errores de tipeo del archivo). Los que ya
  existen: Europastry · Garcia de Pou · Coca Cola · Viñals Gourmet · Teodoro Garcia · Discer · Ruibal Losada ·
  Mercadona · Caprabo · Chef Click.
- **numero**: número de factura / albarán / ticket. **documento**: `factura`, `albaran` o `ticket`.
- **base**: base imponible total del documento (sin IVA). **total**: total a pagar con IVA. Si el documento no
  trae importes (albarán sin precio), no se hace archivo de líneas.
- **dudas**: cualquier cosa que no se lee bien o no cierra. Nunca inventar un número: si un renglón no se lee,
  se anota acá y el renglón se deja afuera.

### Cada renglón

- **codigo**: el código de artículo del proveedor, si el documento lo trae (como texto, con sus ceros). Si no, `null`.
- **descripcion**: el texto del renglón tal cual está impreso.
- **nombre**: nombre corto y claro del producto, con su formato (ej. «Bacon lonchas 1 kg», «Coca-Cola Zero lata 33 cl (24 u)»).
- **categoria**, una de: Carne · Pan · Lácteos y quesos · Verduras y frutas · Salsas y condimentos · Fritos y congelados ·
  Bebidas sin alcohol · Bebidas con alcohol · Postres · Packaging · Limpieza · Otros · Cargos y envases.
- **cantidad** y **unidad**: en la unidad en la que el proveedor pone el precio. Si el precio es por kilo, la
  cantidad son los kilos (`"unidad": "kg"`); si es por caja, las cajas (`"caja"`); si es por unidad, las unidades (`"ud"`).
  Otras: `l`, `pack`, `barril`, `botella`, `lata`, `millar`, `ciento` (Garcia de Pou pone el precio por millar o por ciento).
  Si se vende al peso y el documento no dice los kilos (verdura suelta en un ticket de supermercado): cantidad 1 y
  `"unidad": "compra"`. Con esa unidad la solapa Stock no compara precios, porque cada compra pesa distinto.
- **precio**: precio de una unidad **sin IVA** y con el descuento del renglón ya aplicado (= importe ÷ cantidad).
- **importe**: importe del renglón **sin IVA**.
- **iva**: el % de IVA del renglón (4, 10, 21…).
- **nota** (opcional): promoción, regalo, devolución, «precio pasado de con-IVA a sin-IVA»…

Casos:
- **Tickets de supermercado** (Mercadona, Caprabo): los precios vienen con IVA. Se pasa cada renglón a sin IVA con
  su tipo (sale del cuadro de IVA del pie) y se anota en `nota`.
- **Portes, envases retornables, punto verde, recargos, descuentos al pie**: van como un renglón más, categoría «Cargos y envases»
  (los descuentos y devoluciones, con importe negativo), para que la suma cierre. Los descuentos y promociones que el
  documento aplica a un producto en particular se restan del precio de ese producto (y se anota en `nota`).
  La categoría «Cargos y envases» cuenta en el gasto pero no entra en los cambios de precio.
- **Devoluciones / abonos**: cantidad e importe negativos.
- **Regalos / sin cargo**: cantidad real, precio e importe 0, con nota.

### Comprobación obligatoria

Antes de guardar: la suma de `importe` tiene que dar la `base` (±0,05 €) y la suma de `importe × (1 + iva/100)`
tiene que dar el `total` (±0,05 €). Si no cierra, se revisa la lectura; si sigue sin cerrar, se guarda igual y
se explica en `dudas`.

## Qué no lleva detalle

Servicios y gastos que no son mercadería (luz, agua, gas, seguros, comisiones, software, imprenta, ferretería,
arreglos): no se hace archivo de líneas; se marcan con
`/Users/juan_traverso/.claude/terrys-facturas sin-detalle '<ruta>' '<motivo>'`.
Tampoco los archivos omitidos por duplicados (factura de un albarán ya cargado, mensual de Ruibal).

## Guardar y subir

- Un documento: `/Users/juan_traverso/.claude/terrys-facturas detalle '<json>'` (el JSON de arriba en una sola línea).
  Lo guarda en `facturas/lineas/AAAA-MM/` y lo sube. Si la subida falla, queda guardado y se sube después.
- Lo que quedó sin subir: `/Users/juan_traverso/.claude/terrys-facturas lineas` (`lineas AAAA-MM` solo ese mes;
  `lineas AAAA-MM todo` vuelve a subir también los que ya estaban, por ejemplo después de corregir un JSON).
- Qué hay y qué falta en un mes, y los nombres de proveedores que ya existen: `… stock AAAA-MM`.
