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


def rpc(nombre, cuerpo):
    req = urllib.request.Request(
        CFG['supabaseUrl'].rstrip('/') + '/rest/v1/rpc/' + nombre,
        data=json.dumps(cuerpo).encode('utf-8'),
        headers={'apikey': CFG['supabaseKey'], 'Authorization': 'Bearer ' + CFG['supabaseKey'], 'Content-Type': 'application/json'})
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            return json.loads(r.read().decode('utf-8'))
    except urllib.error.HTTPError as e:
        sys.exit(f"ERROR {e.code}: {e.read().decode('utf-8', 'replace')}")


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
    else:
        sys.exit(__doc__)
