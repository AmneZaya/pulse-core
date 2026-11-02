#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""catalog_tool.py — работа с каталогом шаблонов сайта-маскировки из Python (боты, панели, скрипты).

Копия scripts/catalog_tool.py из навыка site-templates-library; в goAmnezia pro
изменён только путь по умолчанию: каталог лежит рядом с install.sh
(/opt/goamnezia/templates_catalog.json, контракт §1), переопределяется
переменной окружения GOAMNEZIA_CATALOG. Логика чтения/проверки/слияния — как в навыке.

Каталог: templates_catalog.json — {"categories":[{id,name,icon,templates:[{id,name,source,
description,repo_url,sparse_path,preview_url,license?,stars?}]}]}. Файл ~14 МБ, читается за ~50 мс;
кэшируйте по mtime, как здесь, а не перечитывайте на каждый экран.

Как библиотека:
    from catalog_tool import Catalog
    cat = Catalog("/opt/goamnezia/templates_catalog.json")
    cat.categories()                         # [(id, name, count), …]
    cat.page("landing", page=0, per=24)      # (записи, всего_страниц)
    cat.search("cafe", category=None)        # список записей
    cat.random(category="business")          # одна запись
    cat.get("gh_startbootstrap_startbootstrap_business_casual")
    Catalog.short_key(template_id)           # sha1[:12] для callback_data Telegram (≤ 64 байт)

Как утилита:
    catalog_tool.py stats  [файл]
    catalog_tool.py search СЛОВО [--cat ID] [файл]
    catalog_tool.py validate [файл]
    catalog_tool.py merge  ОСНОВНОЙ.json НОВЫЙ.json [-o ВЫХОД.json]   # дедуп по repo_url+sparse_path и id
"""
import hashlib
import json
import os
import random
import re
import sys
from typing import Any, Dict, List, Optional, Tuple

FIELDS = ("id", "name", "source", "description", "repo_url", "sparse_path", "preview_url")
ID_RE = re.compile(r"^[A-Za-z0-9_.-]{1,120}$")


class Catalog:
    def __init__(self, path: str):
        self.path = path
        self._mtime = 0.0
        self._data: Dict[str, Any] = {"categories": []}
        self._index: Dict[str, Dict[str, Any]] = {}
        self.reload()

    def reload(self) -> None:
        try:
            m = os.path.getmtime(self.path)
        except OSError:
            self._data, self._index, self._mtime = {"categories": []}, {}, 0.0
            return
        if m == self._mtime:
            return
        with open(self.path, "r", encoding="utf-8") as f:
            self._data = json.load(f)
        self._index = {t["id"]: dict(t, category=c["id"]) for c in self._data["categories"] for t in c["templates"]}
        self._mtime = m

    # ── чтение ──
    def categories(self) -> List[Tuple[str, str, int]]:
        self.reload()
        return [(c["id"], c["name"], len(c["templates"])) for c in self._data["categories"] if c["templates"]]

    def templates(self, category: str) -> List[Dict[str, Any]]:
        self.reload()
        for c in self._data["categories"]:
            if c["id"] == category:
                return c["templates"]
        return []

    def page(self, category: str, page: int = 0, per: int = 24) -> Tuple[List[Dict[str, Any]], int]:
        items = self.templates(category)
        pages = max(1, (len(items) + per - 1) // per)
        page = max(0, min(page, pages - 1))
        return items[page * per:(page + 1) * per], pages

    def search(self, word: str, category: Optional[str] = None, limit: int = 200) -> List[Dict[str, Any]]:
        self.reload()
        w = word.strip().lower()
        out = []
        for c in self._data["categories"]:
            if category and c["id"] != category:
                continue
            for t in c["templates"]:
                if w in t["name"].lower() or w in t["id"].lower():
                    out.append(dict(t, category=c["id"]))
                    if len(out) >= limit:
                        return out
        return out

    def random(self, category: Optional[str] = None) -> Optional[Dict[str, Any]]:
        self.reload()
        pool = self.templates(category) if category else list(self._index.values())
        return random.choice(pool) if pool else None

    def get(self, template_id: str) -> Optional[Dict[str, Any]]:
        self.reload()
        return self._index.get(template_id)

    @staticmethod
    def short_key(template_id: str) -> str:
        """Короткий ключ для callback_data Telegram; храните map ключ→id в контексте пользователя."""
        return hashlib.sha1(template_id.encode("utf-8")).hexdigest()[:12]

    # ── проверка и слияние ──
    @staticmethod
    def validate(data: Dict[str, Any]) -> List[str]:
        problems: List[str] = []
        ids, urls = set(), set()
        for c in data.get("categories", []):
            for k in ("id", "name", "templates"):
                if k not in c:
                    problems.append(f"категория без поля {k}")
            for t in c.get("templates", []):
                for k in FIELDS:
                    if k not in t:
                        problems.append(f"{t.get('id','?')}: нет поля {k}")
                if not ID_RE.match(str(t.get("id", ""))):
                    problems.append(f"{t.get('id','?')}: плохой id")
                if not str(t.get("repo_url", "")).startswith("https://"):
                    problems.append(f"{t.get('id','?')}: repo_url не https")
                if len(str(t.get("name", "")).strip()) < 2:
                    problems.append(f"{t.get('id','?')}: пустое имя")
                if t.get("id") in ids:
                    problems.append(f"{t['id']}: повтор id")
                key = (str(t.get("repo_url", "")).rstrip("/").lower(), t.get("sparse_path", ""))
                if key in urls:
                    problems.append(f"{t.get('id','?')}: повтор repo_url+sparse_path")
                ids.add(t.get("id")); urls.add(key)
        return problems

    @staticmethod
    def merge(base: Dict[str, Any], new: Dict[str, Any]) -> Tuple[Dict[str, Any], Dict[str, int]]:
        """Добавляет записи new в base; дубли по repo_url+sparse_path и по id отбрасываются.
        Категории, которых нет в base, создаются. Возвращает (каталог, статистика)."""
        bycat = {c["id"]: c for c in base["categories"]}
        ids = {t["id"] for c in base["categories"] for t in c["templates"]}
        urls = {(t["repo_url"].rstrip("/").lower(), t.get("sparse_path", "")) for c in base["categories"] for t in c["templates"]}
        st = {"added": 0, "dup_repo": 0, "dup_id": 0}
        for c in new["categories"]:
            if c["id"] not in bycat:
                bycat[c["id"]] = {"id": c["id"], "name": c.get("name", c["id"]), "icon": c.get("icon", "folder"), "templates": []}
                base["categories"].append(bycat[c["id"]])
            for t in c["templates"]:
                key = (t["repo_url"].rstrip("/").lower(), t.get("sparse_path", ""))
                if key in urls:
                    st["dup_repo"] += 1; continue
                if t["id"] in ids:
                    st["dup_id"] += 1; continue
                e = {k: t.get(k, "") for k in FIELDS}
                if t.get("license"):
                    e["license"] = t["license"]
                if t.get("stars") is not None:
                    e["stars"] = t["stars"]
                bycat[c["id"]]["templates"].append(e)
                ids.add(t["id"]); urls.add(key); st["added"] += 1
        return base, st


def _load(path: str) -> Dict[str, Any]:
    with open(path, "r", encoding="utf-8") as f:
        return json.load(f)


def _default_path() -> str:
    # lib/catalog_tool.py → ../templates_catalog.json (на сервере /opt/goamnezia/templates_catalog.json)
    env = os.environ.get("GOAMNEZIA_CATALOG")
    if env:
        return env
    return os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "templates_catalog.json")


def main(argv: List[str]) -> int:
    if not argv or argv[0] in ("-h", "--help"):
        print(__doc__); return 0
    cmd = argv[0]
    if cmd == "stats":
        cat = Catalog(argv[1] if len(argv) > 1 else _default_path())
        total = sum(n for _, _, n in cat.categories())
        print(f"всего: {total}")
        for cid, name, n in cat.categories():
            print(f"  {cid:14} {n:6}  {name}")
        lic: Dict[str, int] = {}
        for t in cat._index.values():
            lic[t.get("license") or "(нет)"] = lic.get(t.get("license") or "(нет)", 0) + 1
        print("лицензии:", ", ".join(f"{k} {v}" for k, v in sorted(lic.items(), key=lambda x: -x[1])[:10]))
        return 0
    if cmd == "search":
        word = argv[1]; category = None; path = _default_path()
        rest = argv[2:]
        if "--cat" in rest:
            i = rest.index("--cat"); category = rest[i + 1]; rest = rest[:i] + rest[i + 2:]
        if rest:
            path = rest[0]
        for t in Catalog(path).search(word, category):
            print(f"{t['id']:60} {t['category']:12} {t['name']}")
        return 0
    if cmd == "validate":
        problems = Catalog.validate(_load(argv[1] if len(argv) > 1 else _default_path()))
        print("проблем:", len(problems))
        for p in problems[:50]:
            print("  ", p)
        return 1 if problems else 0
    if cmd == "merge":
        base, new = _load(argv[1]), _load(argv[2])
        out = argv[argv.index("-o") + 1] if "-o" in argv else argv[1]
        merged, st = Catalog.merge(base, new)
        problems = Catalog.validate(merged)
        if problems:
            print("слияние отменено, проблемы:", problems[:10]); return 1
        with open(out, "w", encoding="utf-8") as f:
            json.dump(merged, f, ensure_ascii=False, indent=2); f.write("\n")
        print(f"добавлено {st['added']}, дублей repo {st['dup_repo']}, id {st['dup_id']} → {out}")
        return 0
    print("неизвестная команда:", cmd); return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
