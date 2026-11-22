#!/usr/bin/env python3
"""Arma data/bo.json (campañas y DDJJ del BO de Lannis) para el dashboard.

Las consultas se corren con la herramienta run_readonly_query del MCP de Lannis
(no hay acceso directo a la base desde acá). El flujo es:

  1. python3 scripts/bo/build.py render
     Escribe en scripts/bo/out/ las consultas listas para correr (*.sql, con los
     templates de campanias.json ya reemplazados).
  2. Correr cada scripts/bo/out/<nombre>.sql con run_readonly_query y guardar el
     valor de la columna j (o la respuesta completa del MCP) en scripts/bo/out/<nombre>.json.
  3. (Opcional) Escribir el análisis de campañas en scripts/bo/out/analisis.json:
     {"semanal": {"periodo": "YYYY-MM-DD" (lunes de la semana), "puntos": ["...", ...]},
      "mensual": {"periodo": "YYYY-MM", "puntos": ["...", ...]}}   (cualquiera de las dos claves)
  4. python3 scripts/bo/build.py build
     Valida los resultados y escribe data/bo.json. Nunca incluye CUITs, emails ni
     nombres de clientes: solo agregados. El análisis se suma al historial (últimos 12 de cada tipo).
"""
import re
import json
import sys
from datetime import datetime, timezone, timedelta
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
BO = ROOT / "scripts" / "bo"
OUT = BO / "out"
DATA = ROOT / "data" / "bo.json"
QUERIES = ["campanias", "ddjj_estado", "ddjj_semanal", "facturacion", "clics"]
ART = timezone(timedelta(hours=-3))


def config():
    return json.loads((BO / "campanias.json").read_text(encoding="utf-8"))


def render():
    cfg = config()
    tpls = [t["template"] for g in cfg["grupos"] for t in g["templates"]]
    OUT.mkdir(parents=True, exist_ok=True)
    for q in QUERIES:
        sql = (BO / "queries" / f"{q}.sql").read_text(encoding="utf-8")
        sql = sql.replace("{{TEMPLATES}}", ",".join("'" + t.replace("'", "''") + "'" for t in tpls))
        sql = sql.replace("{{DIAS}}", str(int(cfg.get("ventanaConversionDias", 14))))
        # sin comentarios ni saltos de línea: más fácil de pasar al MCP
        lines = [l.split("--")[0].rstrip() if not l.strip().startswith("--") else "" for l in sql.splitlines()]
        (OUT / f"{q}.sql").write_text(" ".join(l.strip() for l in lines if l.strip()) + "\n", encoding="utf-8")
        print(f"scripts/bo/out/{q}.sql")


def load(q):
    p = OUT / f"{q}.json"
    if not p.exists():
        sys.exit(f"Falta {p}: corré scripts/bo/out/{q}.sql con run_readonly_query y guardá el resultado ahí.")
    v = json.loads(p.read_text(encoding="utf-8"))
    if isinstance(v, dict) and "rows" in v:  # respuesta completa del MCP
        v = v["rows"][0]
    if isinstance(v, dict) and "j" in v:
        v = v["j"]
    if isinstance(v, str):
        v = json.loads(v)
    return v


PII = [re.compile(r"[\w.+-]+@[\w-]+\.[\w.]+"), re.compile(r"\b\d{2}-?\d{8}-?\d\b"), re.compile(r"\d{8,}")]


def merge_analisis(prev):
    hist = {"semanal": dict((prev or {}).get("semanal") or {}), "mensual": dict((prev or {}).get("mensual") or {})}
    p = OUT / "analisis.json"
    if p.exists():
        new = json.loads(p.read_text(encoding="utf-8"))
        for tipo, fmt in (("semanal", r"^\d{4}-\d{2}-\d{2}$"), ("mensual", r"^\d{4}-\d{2}$")):
            a = new.get(tipo)
            if not a:
                continue
            per, puntos = str(a.get("periodo", "")), a.get("puntos") or []
            assert re.match(fmt, per), f"analisis.{tipo}.periodo inválido: {per}"
            assert isinstance(puntos, list) and 1 <= len(puntos) <= 10 and all(isinstance(x, str) and 0 < len(x) <= 400 for x in puntos), f"analisis.{tipo}.puntos inválido"
            for x in puntos:
                for rx in PII:
                    assert not rx.search(x), f"analisis.{tipo} tiene algo que parece un dato personal (email, CUIT o teléfono): {x[:80]}"
            hist[tipo][per] = {"puntos": puntos, "generado": datetime.now(ART).strftime("%Y-%m-%d")}
    for tipo in hist:
        hist[tipo] = dict(sorted(hist[tipo].items())[-12:])
    return hist


def build():
    cfg = config()
    camp, est, sem, fac, cli = (load(q) for q in QUERIES)
    for k in ("funnel", "daily"):
        assert isinstance(camp.get(k), (list, type(None))), f"campanias.{k} inválido"
    for k in ("snapshot", "periodos", "excluidas"):
        assert k in est, f"ddjj_estado sin {k}"
    for k in ("stagesBySeg", "stagesByFam", "presentadas", "moves", "team"):
        assert k in sem, f"ddjj_semanal sin {k}"
    for k in ("total", "daily"):
        assert isinstance(cli.get(k), (list, type(None))), f"clics.{k} inválido"
    for r in (cli.get("total") or []) + (cli.get("daily") or []):
        assert not re.search(r"@|%40|\?|=", str(r[1])), f"clics: un destino parece tener datos personales: {r[1][:60]}"
    for k in ("semanas", "meses", "activosHoy"):
        assert k in fac, f"facturacion sin {k}"

    now = datetime.now(ART)
    prev = {}
    if DATA.exists():
        try:
            prev = json.loads(DATA.read_text(encoding="utf-8"))
        except Exception:
            prev = {}

    # Historial de vencidas / abiertas: no se puede reconstruir hacia atrás, así que se guarda una foto por semana.
    snap = est.get("snapshot") or []
    pres = {"PRESENTADA", "PENDIENTE_PAGO", "PAGO_INFORMADO", "PAGADA", "COMPLETADA"}
    week = (now - timedelta(days=now.weekday())).strftime("%Y-%m-%d")
    foto = {
        "semana": week,
        "abiertas": sum(r[3] for r in snap if r[2] not in pres),
        "vencidas": sum(r[4] for r in snap),
        "vencen7": sum(r[5] for r in snap),
        "trabadas7": sum(r[6] for r in snap),
    }
    hist = [h for h in (prev.get("ddjj", {}).get("historial") or []) if h.get("semana") != week]
    hist = sorted(hist + [foto], key=lambda h: h["semana"])[-26:]

    out = {
        "generado": now.strftime("%Y-%m-%dT%H:%M:%S-03:00"),
        "campanias": {
            "generado": now.strftime("%Y-%m-%dT%H:%M:%S-03:00"),
            "ventanaDias": cfg.get("ventanaConversionDias", 14),
            "grupos": cfg["grupos"],
            "funnel": camp.get("funnel") or [],
            "daily": camp.get("daily") or [],
            "links": cli.get("total") or [],
            "linksDaily": cli.get("daily") or [],
            "linksDesde": cli.get("desde"),
        },
        "ddjj": {**est, **sem, "historial": hist},
        "facturacion": fac,
        "analisis": merge_analisis(prev.get("analisis")),
    }
    DATA.parent.mkdir(parents=True, exist_ok=True)
    DATA.write_text(json.dumps(out, ensure_ascii=False, separators=(",", ":")) + "\n", encoding="utf-8")
    print(f"data/bo.json · {DATA.stat().st_size/1024:.1f} KB · generado {out['generado']}")


if __name__ == "__main__":
    {"render": render, "build": build}.get(sys.argv[1] if len(sys.argv) > 1 else "", lambda: sys.exit(__doc__))()
