#!/usr/bin/env python3
"""Terry's Administración — facturas de Drive a la bandeja "por revisar".

Lo usa Claude (no hace falta correrlo a mano):

  python3 facturas/facturas.py listar [2026-10]        archivos de la carpeta (todo el año o un mes) y si ya están cargados
  python3 facturas/facturas.py pedidos                 pedidos pendientes del botón "Actualizar facturas" de la página
  python3 facturas/facturas.py pedido 12 listo '{...}' marca un pedido (en curso / listo / error) con un resumen
  python3 facturas/facturas.py pedir 2026-10           crea un pedido (igual que el botón)
  python3 facturas/facturas.py novedades               chequeo diario: archivos sin cargar del mes en curso y del anterior
  python3 facturas/facturas.py omitir '<ruta>' '<motivo>'   anota un archivo que no se carga (no vuelve a salir como pendiente)
  python3 facturas/facturas.py omitidos                lista de archivos omitidos
  python3 facturas/facturas.py subir '<json>'          sube una factura leída; el json lleva:
        {"ruta": "2026/10_Octubre/archivo.pdf", "fecha": "2026-10-01", "total": 138.59,
         "proveedor": "Europastry", "detalle": "Reposicion panes", "nota": "Factura 24015086 · vence 06/10 · giro"}
        opcionales: "ingreso": true (abonos, liquidaciones: va a Ingresos; Tipo "Ingreso", Desde proveedor, Hacia "CAIXA"),
        "tipo"/"desde"/"hacia" para fijarlos, "reemplazar": true para corregir una fila propia todavía sin aprobar.

Detalle para la solapa Stock (ver facturas/LINEAS.md):
  python3 facturas/facturas.py detalle '<json>'             guarda el detalle de un documento (facturas/lineas/AAAA-MM/) y lo sube
  python3 facturas/facturas.py lineas [2026-11] [todo]      sube los JSON de facturas/lineas/ que todavía no están en la base
                                                            ("todo": vuelve a subir también los que ya estaban)
  python3 facturas/facturas.py sin-detalle '<ruta>' '<motivo>'   marca un documento que no lleva renglones (luz, agua, comisiones…)
  python3 facturas/facturas.py catalogo [proveedor]         productos ya leídos de ese proveedor (código, nombre, categoría, unidad)
  python3 facturas/facturas.py stock [2026-11]              qué archivos del mes tienen detalle, cuáles no y los proveedores que ya existen

La carpeta de Drive tiene que estar sincronizada en esta Mac (Google Drive para escritorio):
el id de cada archivo se lee del atributo que le pone Drive, y con ese id se arma el link
y se evita cargar dos veces la misma factura aunque se renombre o se mueva.
La configuración (URL, clave pública y token) está en facturas/config.json, que no se sube al repositorio.
Los archivos que no se cargan (mensual de Ruibal, Harmonia, duplicados, cargados a mano…) se anotan en
facturas/omitidos.json (tampoco se sube) para no volver a leerlos en cada chequeo.
"""
import datetime, json, os, subprocess, sys, urllib.request, urllib.error

AQUI = os.path.dirname(os.path.abspath(__file__))
CFG = json.load(open(os.path.join(AQUI, 'config.json'), encoding='utf-8'))
CARPETA = os.path.expanduser(CFG['carpeta'])
EXT = ('.pdf', '.jpg', '.jpeg', '.png', '.heic', '.webp')
OMITIDOS = os.path.join(AQUI, 'omitidos.json')


def leer_omitidos():
    try:
        return json.load(open(OMITIDOS, encoding='utf-8'))
    except FileNotFoundError:
        return []


def motivo_omitido(a, om):
    """Motivo si el archivo está anotado como omitido (por id de Drive o por ruta), si no None."""
    for o in om:
        if (a.get('id') and o.get('id') == a['id']) or o.get('ruta') == a['ruta']:
            return o.get('motivo') or 'omitido'
    return None


def drive_id(ruta):
    try:
        return subprocess.run(['xattr', '-p', 'com.google.drivefs.item-id#S', ruta], capture_output=True, text=True).stdout.strip() or None
    except Exception:
        return None


def rpc(nombre, cuerpo, fatal=True):
    req = urllib.request.Request(
        CFG['supabaseUrl'].rstrip('/') + '/rest/v1/rpc/' + nombre,
        data=json.dumps(cuerpo).encode('utf-8'),
        headers={'apikey': CFG['supabaseKey'], 'Authorization': 'Bearer ' + CFG['supabaseKey'], 'Content-Type': 'application/json'})
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            return json.loads(r.read().decode('utf-8'))
    except urllib.error.HTTPError as e:
        msg = f"ERROR {e.code}: {e.read().decode('utf-8', 'replace')}"
        if fatal:
            sys.exit(msg)
        return {'estado': 'error', 'error': msg}


def archivos(mes=None):
    out = []
    for raiz, _, nombres in os.walk(CARPETA):
        for n in sorted(nombres):
            if n.startswith('.') or not n.lower().endswith(EXT):
                continue
            ruta = os.path.join(raiz, n)
            rel = os.path.relpath(ruta, CARPETA)
            if mes:  # "2026-10" → carpeta 2026/10_...
                a, m = mes.split('-')
                partes = rel.split(os.sep)
                if len(partes) < 3 or partes[0] != a or not partes[1].startswith(m + '_'):
                    continue
            out.append({'ruta': rel, 'id': drive_id(ruta)})
    return sorted(out, key=lambda x: x['ruta'])


def con_estado(mes=None):
    l = archivos(mes)
    ids = [a['id'] for a in l if a['id']]
    estado = rpc('facturas_estado', {'p_token': CFG['token'], 'p_archivos': ids, 'p_empresa': CFG['empresa']}) if ids else {}
    om = leer_omitidos()
    for a in l:
        a['cargada'] = estado.get(a['id']) if a['id'] else None   # también trae {'descartada': true} si alguien borró su fila
        m = motivo_omitido(a, om)
        if m and not a['cargada']:
            a['omitida'] = m
    return l


def listar(mes=None):
    l = con_estado(mes)
    print(json.dumps(l, ensure_ascii=False, indent=1))
    om = [a for a in l if a.get('omitida')]
    pend = [a for a in l if a['id'] and not a['cargada'] and not a.get('omitida')]
    print(f"\n{len(l)} archivos · {len(l) - len(pend) - len(om)} cargados · {len(om)} omitidos · {len(pend)} pendientes", file=sys.stderr)


def novedades():
    """Chequeo diario: lo que falta cargar del mes en curso y del anterior (por si algo llegó tarde)."""
    hoy = datetime.date.today()
    ant = hoy.replace(day=1) - datetime.timedelta(days=1)
    out = []
    for per in (f'{ant:%Y-%m}', f'{hoy:%Y-%m}'):
        l = [a for a in con_estado(per) if not a['cargada'] and not a.get('omitida')]
        out.append({'periodo': per,
                    'pendientes': [a['ruta'] for a in l if a['id']],
                    'sin_sincronizar': [a['ruta'] for a in l if not a['id']]})   # Drive todavía no les puso id: se reintenta mañana
    print(json.dumps(out, ensure_ascii=False, indent=1))


def omitir(rel, motivo):
    ruta = os.path.join(CARPETA, rel)
    if not os.path.isfile(ruta):
        sys.exit('No existe el archivo: ' + ruta)
    om = [o for o in leer_omitidos() if o.get('ruta') != rel]
    om.append({'ruta': rel, 'id': drive_id(ruta), 'motivo': motivo, 'fecha': f'{datetime.date.today():%Y-%m-%d}'})
    with open(OMITIDOS, 'w', encoding='utf-8') as f:
        json.dump(sorted(om, key=lambda o: o['ruta']), f, ensure_ascii=False, indent=1)
    print(json.dumps({'ruta': rel, 'omitida': motivo}, ensure_ascii=False))


def subir(datos):
    ruta = os.path.join(CARPETA, datos['ruta'])
    if not os.path.isfile(ruta):
        sys.exit('No existe el archivo: ' + ruta)
    fid = drive_id(ruta)
    if not fid:
        sys.exit('El archivo no tiene id de Drive (¿está sincronizado?): ' + ruta)
    cuerpo = {'archivo': fid, 'link': f'https://drive.google.com/file/d/{fid}/view',
              'fecha': datos['fecha'], 'total': datos['total'], 'proveedor': datos.get('proveedor', ''),
              'detalle': datos.get('detalle', ''), 'nota': datos.get('nota', '')}
    for k in ('ingreso', 'tipo', 'desde', 'hacia', 'reemplazar', 'forzar'):   # opcionales (ver schema.sql, subir_factura)
        if k in datos:
            cuerpo[k] = datos[k]
    r = rpc('subir_factura', {'p_token': CFG['token'], 'p_datos': cuerpo, 'p_empresa': CFG['empresa']})
    print(json.dumps({'ruta': datos['ruta'], **r}, ensure_ascii=False))


# ---------- detalle de las facturas para la solapa Stock ----------
LINEAS = os.path.join(AQUI, 'lineas')


def fecha_de_ruta(rel):
    """«2026/11_Noviembre/1103_Proveedor_Detalle.pdf» → 2026-11-03 (la fecha es la del nombre del archivo, como en Compras).
    Si el nombre no trae fecha, el día 1 del mes de la carpeta."""
    partes = rel.split(os.sep)
    n = partes[-1]
    while n and not n[0].isdigit():          # «RECLAMAR_1116_…»
        n = n.split('_', 1)[1] if '_' in n else ''
    if len(partes) >= 3 and len(n) >= 4 and n[:4].isdigit():
        return f'{partes[0]}-{n[:2]}-{n[2:4]}'
    if len(partes) >= 3 and partes[1][:2].isdigit():      # sin fecha en el nombre: el día 1 del mes de la carpeta
        return f'{partes[0]}-{partes[1][:2]}-01'
    sys.exit('No se puede sacar la fecha del nombre: ' + rel)


def stock_estado(ids):
    return rpc('stock_estado', {'p_token': CFG['token'], 'p_archivos': ids}, fatal=False)


def subir_lineas_de(datos):
    ruta = os.path.join(CARPETA, datos['ruta'])
    if not os.path.isfile(ruta):
        return {'ruta': datos['ruta'], 'estado': 'error', 'error': 'no existe el archivo en Drive'}
    fid = drive_id(ruta)
    if not fid:
        return {'ruta': datos['ruta'], 'estado': 'error', 'error': 'sin id de Drive (¿está sincronizado?)'}
    cuerpo = {'archivo': fid, 'link': f'https://drive.google.com/file/d/{fid}/view', 'ruta': datos['ruta'],
              'fecha': datos.get('fecha') or fecha_de_ruta(datos['ruta'])}
    for k in ('proveedor', 'numero', 'documento', 'base', 'total', 'nota', 'sin_detalle', 'lineas'):
        if datos.get(k) is not None:
            cuerpo[k] = datos[k]
    r = rpc('subir_lineas', {'p_token': CFG['token'], 'p_datos': cuerpo, 'p_empresa': CFG['empresa']}, fatal=False)
    return {'ruta': datos['ruta'], **r}


def detalle(datos):
    """Guarda el detalle de un documento en facturas/lineas/AAAA-MM/ y lo sube. Si la subida falla queda guardado:
    lo sube después `lineas`."""
    if not datos.get('ruta') or not datos.get('proveedor') or not datos.get('lineas'):
        sys.exit('Hacen falta ruta, proveedor y lineas (ver facturas/LINEAS.md)')
    suma = round(sum(float(l['importe']) for l in datos['lineas']), 2)
    f = fecha_de_ruta(datos['ruta'])
    carpeta = os.path.join(LINEAS, f[:7])
    os.makedirs(carpeta, exist_ok=True)
    with open(os.path.join(carpeta, os.path.basename(datos['ruta']) + '.json'), 'w', encoding='utf-8') as fh:
        json.dump(datos, fh, ensure_ascii=False, indent=1)
    r = subir_lineas_de(datos)
    if datos.get('base') is not None and abs(suma - float(datos['base'])) > 0.05:
        r['aviso'] = f"la suma de los renglones ({suma}) no da la base ({datos['base']}): revisar la lectura"
    print(json.dumps(r, ensure_ascii=False))


def lineas(mes=None, todo=False):
    """Sube los JSON de facturas/lineas/AAAA-MM/ que todavía no están en la base."""
    js = []
    for raiz, _, nombres in os.walk(LINEAS):
        if mes and os.path.basename(raiz) != mes:
            continue
        for n in sorted(nombres):
            if n.endswith('.json'):
                js.append(json.load(open(os.path.join(raiz, n), encoding='utf-8')))
    ids = {}
    for d in js:
        ruta = os.path.join(CARPETA, d['ruta'])
        ids[d['ruta']] = drive_id(ruta) if os.path.isfile(ruta) else None
    ya = stock_estado([i for i in ids.values() if i]).get('archivos', {}) if js else {}
    out = []
    for d in js:
        if not todo and ids[d['ruta']] in ya:
            continue
        out.append(subir_lineas_de(d))
    print(json.dumps(out, ensure_ascii=False, indent=1))
    mal = [o for o in out if o.get('estado') == 'error' or abs(o.get('diferencia') or 0) > 0.05]
    print(f"\n{len(js)} documentos con detalle · {len(out)} subidos ahora · {len(mal)} para revisar", file=sys.stderr)


def sin_detalle(rel, motivo):
    print(json.dumps(subir_lineas_de({'ruta': rel, 'sin_detalle': True, 'nota': motivo,
                                      'proveedor': (os.path.basename(rel).split('_') + ['', ''])[1]}), ensure_ascii=False))


def stock(mes=None):
    """Qué archivos tienen detalle en Stock, cuáles no, y los proveedores que ya existen (para escribirlos igual)."""
    l = con_estado(mes)
    e = stock_estado([a['id'] for a in l if a['id']])
    arch = e.get('archivos', {})
    locales = set()
    for raiz, _, nombres in os.walk(LINEAS):
        for n in nombres:
            if n.endswith('.json'):
                locales.add(n[:-5])
    out = {'proveedores': e.get('proveedores', []), 'con_detalle': [], 'sin_detalle': [], 'falta': [], 'leido_sin_subir': []}
    for a in l:
        s = arch.get(a['id']) if a['id'] else None
        if s:
            out['sin_detalle' if s['sin_detalle'] else 'con_detalle'].append(a['ruta'])
        elif os.path.basename(a['ruta']) in locales:
            out['leido_sin_subir'].append(a['ruta'])
        elif not a.get('omitida'):
            out['falta'].append(a['ruta'])
    print(json.dumps(out, ensure_ascii=False, indent=1))


def catalogo(prov=None):
    """Productos ya leídos (de los JSON locales), por proveedor: para escribir igual el nombre, la categoría y la unidad."""
    cat = {}
    for raiz, _, nombres in os.walk(LINEAS):
        for n in sorted(nombres):
            if not n.endswith('.json'):
                continue
            d = json.load(open(os.path.join(raiz, n), encoding='utf-8'))
            if prov and prov.lower() not in d.get('proveedor', '').lower():
                continue
            for l in d.get('lineas', []):
                k = l.get('codigo') or l['descripcion']
                cat.setdefault(d['proveedor'], {})[k] = {'codigo': l.get('codigo'), 'descripcion': l['descripcion'], 'nombre': l.get('nombre'),
                                                         'categoria': l.get('categoria'), 'unidad': l.get('unidad'), 'iva': l.get('iva')}
    print(json.dumps({p: list(v.values()) for p, v in sorted(cat.items())}, ensure_ascii=False, indent=1))


def pedidos():
    print(json.dumps(rpc('pedidos_pendientes', {'p_token': CFG['token'], 'p_empresa': CFG['empresa']}), ensure_ascii=False))


def pedido(id_, estado, resultado=None):
    print(json.dumps(rpc('pedido_estado', {'p_token': CFG['token'], 'p_id': int(id_), 'p_estado': estado, 'p_resultado': json.loads(resultado) if resultado else None}), ensure_ascii=False))


def pedir(periodo):
    print(json.dumps(rpc('pedido_crear', {'p_token': CFG['token'], 'p_periodo': periodo, 'p_empresa': CFG['empresa']}), ensure_ascii=False))


if __name__ == '__main__':
    if len(sys.argv) >= 2 and sys.argv[1] == 'pedidos':          # pedidos pendientes del botón "Actualizar facturas"
        pedidos()
    elif len(sys.argv) >= 4 and sys.argv[1] == 'pedido':         # pedido <id> <en curso|listo|error> ['<json resumen>']
        pedido(sys.argv[2], sys.argv[3], sys.argv[4] if len(sys.argv) > 4 else None)
    elif len(sys.argv) == 3 and sys.argv[1] == 'pedir':          # pedir 2026-10  (crea un pedido como desde el botón)
        pedir(sys.argv[2])
    elif len(sys.argv) == 2 and sys.argv[1] == 'novedades':      # chequeo diario (mes en curso y anterior)
        novedades()
    elif len(sys.argv) == 4 and sys.argv[1] == 'omitir':         # omitir '<ruta>' '<motivo>'
        omitir(sys.argv[2], sys.argv[3])
    elif len(sys.argv) == 2 and sys.argv[1] == 'omitidos':
        print(json.dumps(leer_omitidos(), ensure_ascii=False, indent=1))
    elif len(sys.argv) >= 2 and sys.argv[1] == 'listar':
        listar(sys.argv[2] if len(sys.argv) > 2 else None)
    elif len(sys.argv) == 3 and sys.argv[1] == 'subir':
        subir(json.loads(sys.argv[2]))
    elif len(sys.argv) == 3 and sys.argv[1] == 'detalle':        # detalle '<json>'  (formato en LINEAS.md)
        detalle(json.loads(sys.argv[2]))
    elif len(sys.argv) >= 2 and sys.argv[1] == 'lineas':         # lineas [2026-11] [todo]
        args = sys.argv[2:]
        lineas(next((a for a in args if a != 'todo'), None), 'todo' in args)
    elif len(sys.argv) == 4 and sys.argv[1] == 'sin-detalle':    # sin-detalle '<ruta>' '<motivo>'
        sin_detalle(sys.argv[2], sys.argv[3])
    elif len(sys.argv) >= 2 and sys.argv[1] == 'catalogo':       # catalogo [proveedor]
        catalogo(sys.argv[2] if len(sys.argv) > 2 else None)
    elif len(sys.argv) >= 2 and sys.argv[1] == 'stock':          # stock [2026-11]
        stock(sys.argv[2] if len(sys.argv) > 2 else None)
    else:
        sys.exit(__doc__)
