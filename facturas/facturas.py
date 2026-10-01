#!/usr/bin/env python3
"""Terry's Administración — facturas de Drive a la bandeja "por revisar".

Lo usa Claude (no hace falta correrlo a mano):

  python3 facturas/facturas.py listar [2026-10]        archivos de la carpeta (todo el año o un mes) y si ya están cargados
  python3 facturas/facturas.py subir '<json>'          sube una factura leída; el json lleva:
        {"ruta": "2026/10_Octubre/archivo.pdf", "fecha": "2026-10-01", "total": 138.59,
         "proveedor": "Europastry", "detalle": "Reposicion panes", "nota": "Factura 24015086 · vence 06/10 · giro"}
        opcionales: "ingreso": true (abonos, liquidaciones: va a Ingresos; Tipo "Ingreso", Desde proveedor, Hacia "CAIXA"),
        "tipo"/"desde"/"hacia" para fijarlos, "reemplazar": true para corregir una fila propia todavía sin aprobar.

La carpeta de Drive tiene que estar sincronizada en esta Mac (Google Drive para escritorio):
el id de cada archivo se lee del atributo que le pone Drive, y con ese id se arma el link
y se evita cargar dos veces la misma factura aunque se renombre o se mueva.
La configuración (URL, clave pública y token) está en facturas/config.json, que no se sube al repositorio.
"""
import json, os, subprocess, sys, urllib.request, urllib.error

AQUI = os.path.dirname(os.path.abspath(__file__))
CFG = json.load(open(os.path.join(AQUI, 'config.json'), encoding='utf-8'))
CARPETA = os.path.expanduser(CFG['carpeta'])
EXT = ('.pdf', '.jpg', '.jpeg', '.png', '.heic', '.webp')


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


def listar(mes=None):
    l = archivos(mes)
    ids = [a['id'] for a in l if a['id']]
    estado = rpc('facturas_estado', {'p_token': CFG['token'], 'p_archivos': ids, 'p_empresa': CFG['empresa']}) if ids else {}
    for a in l:
        e = estado.get(a['id']) if a['id'] else None
        a['cargada'] = e
    print(json.dumps(l, ensure_ascii=False, indent=1))
    pend = [a for a in l if a['id'] and not a['cargada']]
    print(f"\n{len(l)} archivos · {len(l) - len(pend)} cargados · {len(pend)} pendientes", file=sys.stderr)


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
    for k in ('ingreso', 'tipo', 'desde', 'hacia', 'reemplazar'):   # opcionales (ver schema.sql, subir_factura)
        if k in datos:
            cuerpo[k] = datos[k]
    r = rpc('subir_factura', {'p_token': CFG['token'], 'p_datos': cuerpo, 'p_empresa': CFG['empresa']})
    print(json.dumps({'ruta': datos['ruta'], **r}, ensure_ascii=False))


if __name__ == '__main__':
    if len(sys.argv) >= 2 and sys.argv[1] == 'listar':
        listar(sys.argv[2] if len(sys.argv) > 2 else None)
    elif len(sys.argv) == 3 and sys.argv[1] == 'subir':
        subir(json.loads(sys.argv[2]))
    else:
        sys.exit(__doc__)
