"""Run the product ticket-list queries against Fabric and verify their output.

Each query file is executed exactly as stored. Its output is checked against
figures computed independently, keyed on CV customer ID throughout.

Usage:
    python tests/test_blast_queries.py                  # test working copies
    python tests/test_blast_queries.py --baseline HEAD  # also diff vs a git ref
    python tests/test_blast_queries.py --only "Elite Edge"
    python tests/test_blast_queries.py --test-ref HEAD  # test a committed version

Requires the deep-dive MCP server checkout (Fabric auth via `az login`).
Set DEEP_DIVE_PATH if it is not at ~/deep-dive.
"""
import argparse
import csv
import os
import re
import subprocess
import sys
from collections import Counter, defaultdict
from datetime import date, datetime
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
DEEP_DIVE = Path(os.environ.get("DEEP_DIVE_PATH", Path.home() / "deep-dive"))
sys.path.insert(0, str(DEEP_DIVE))
from tools.helpers import connect  # noqa: E402

WORKSPACE, LAKEHOUSE = "Bizops.IT_Data_Gateway.Lakehouse", "IT_Data_Gateway"
HUB, DWH, NS = "IT_Data_Gateway.[10XHub]", "IT_Data_Gateway.DWH", "IT_Data_Gateway.NetSuite"

QUERIES = {
    "10X360":     {"file": "10X360 Tickets.sql",     "old_file": "10X360 Undecided Blast.sql",     "like": "%10X360%"},
    "Essentials": {"file": "Essentials Tickets.sql", "old_file": "Essentials Undecided Blast.sql", "like": "%Essential%"},
    "Elite Edge": {"file": "Elite Edge Tickets.sql", "old_file": "Elite Edge Undecided Blast.sql", "like": "%Elite Edge%"},
}

ELITE_MAP = {"3": "E125", "4": "E250"}
STATUS_COLS = {"open": "TM_Open", "undecided": "TM_Undecided", "undecided_at_sale": "TM_UndecidedAtSale",
               "expired": "TM_Expired", "assigned": "TM_Assigned", "scheduled": "TM_Scheduled",
               "reserved": "TM_Reserved", "attended": "TM_Attended", "no show": "TM_NoShow",
               "cancelled": "TM_Cancelled"}
UNSCHEDULED = ("open", "undecided", "undecided_at_sale", "expired")


def run(sql):
    conn = connect(WORKSPACE, LAKEHOUSE)
    try:
        cur = conn.cursor()
        cur.execute(sql)
        cols = [d[0] for d in cur.description]
        return [dict(zip(cols, r)) for r in cur.fetchall()]
    finally:
        conn.close()


def cv_set(sql):
    return {r["cv"] for r in run(sql) if r["cv"]}


def as_date(v):
    if v is None:
        return None
    return v.date() if isinstance(v, datetime) else v if isinstance(v, date) else date.fromisoformat(str(v)[:10])


def prefix_bare_schemas(sql):
    # Older committed versions used bare [10XHub]/[DWH]/[NetSuite] names
    return re.sub(r"([^.A-Za-z_])\[(10XHub|DWH|NetSuite)\]\.", r"\1IT_Data_Gateway.[\2].", sql)


def load_sql(cfg, ref=None):
    if not ref:
        return (REPO / cfg["file"]).read_text(encoding="utf-8")
    for name in (cfg["file"], cfg["old_file"]):
        res = subprocess.run(["git", "show", f"{ref}:{name}"], cwd=REPO,
                             capture_output=True, text=True, encoding="utf-8")
        if res.returncode == 0:
            return prefix_bare_schemas(res.stdout)
    raise FileNotFoundError(f"{cfg['file']} not found at {ref}")


def reference(cfg):
    like = cfg["like"]
    tickets = f"""
        SELECT t.*, LOWER(t.status) AS st, c.cv_customer_id AS cv, tr.transaction_date AS bought
        FROM {HUB}.tickets t
        INNER JOIN {HUB}.customers c ON c.id = t.customer_id
        LEFT JOIN {HUB}.transactions tr ON tr.cv_transaction_id = t.transaction_id
        WHERE t.product_name LIKE '{like}' AND t.is_deleted = 0"""
    per_cv = defaultdict(lambda: {"counts": Counter(), "bought": [], "next": [], "attended": []})
    today = date.today()
    for r in run(f"SELECT cv, st, bought, event_date FROM ({tickets}) x"):
        p = per_cv[r["cv"]]
        p["counts"][r["st"]] += 1
        if r["bought"]:
            p["bought"].append(as_date(r["bought"]))
        if r["st"] in ("scheduled", "reserved") and r["event_date"] and as_date(r["event_date"]) >= today:
            p["next"].append(as_date(r["event_date"]))
        if r["st"] == "attended" and r["event_date"]:
            p["attended"].append(as_date(r["event_date"]))
    has_contact = cv_set(f"""
        WITH tk AS ({tickets})
        SELECT tk.cv FROM tk
        LEFT JOIN {HUB}.transactions tr ON tr.cv_transaction_id = tk.transaction_id
        WHERE (tk.purchaser_email NOT IN ('FabricImport','') AND tk.purchaser_email IS NOT NULL)
           OR (tr.purchaser_email NOT IN ('FabricImport','') AND tr.purchaser_email IS NOT NULL)
        UNION
        SELECT c.cv_customer_id FROM {HUB}.attendees a INNER JOIN {HUB}.customers c ON c.id = a.customer_id
        WHERE c.cv_customer_id IN (SELECT cv FROM tk)
          AND a.attendee_email IS NOT NULL AND a.attendee_email NOT LIKE '%+placeholder@%'
        UNION
        SELECT dc.CVCustomerID FROM {DWH}.DimCustomer dc
        INNER JOIN {NS}.silver_Entity se ON se.EntityID = dc.NetSuiteID
        WHERE dc.CVCustomerID IN (SELECT cv FROM tk) AND se.Email IS NOT NULL AND se.Email != ''
        UNION
        SELECT dcc.Customer FROM {DWH}.DimCustomerContact dcc
        INNER JOIN {DWH}.DimPerson dp ON dp.CVPersonID = dcc.Person
        WHERE dcc.Customer IN (SELECT cv FROM tk) AND dcc.StaffTitleName = 'Owner' AND dcc.IsActiveName = 'Yes'
          AND dp.Email IS NOT NULL AND dp.Email != ''""")
    first_10x360 = {r["cv"]: as_date(r["d"]) for r in run(f"""
        SELECT f.CVCustomerID cv, MIN(f.GLDate) d FROM {DWH}.FactGL f
        INNER JOIN {DWH}.DimProduct dp ON dp.CVProductID = f.CVProductID
        WHERE dp.ProductName LIKE '%10X360%' AND f.GLLineID != 0 AND f.SalesOrderCashCollected > 0
          AND f.CVCustomerID IS NOT NULL
        GROUP BY f.CVCustomerID""")}
    # DimCustomer.EliteStatus is the master; FactGL.Elite is only a per-transaction tag
    dim = {r["cv"]: r for r in run(f"SELECT CVCustomerID cv, EliteStatus s, VerticalName v, SubVerticalName sv FROM {DWH}.DimCustomer")}
    elite = {cv: ELITE_MAP.get(str(r["s"])) for cv, r in dim.items()}
    touches = {r["cv"]: r for r in run(f"""
        SELECT c.cv_customer_id cv,
               MAX(CASE WHEN t.product_name LIKE '{like}' THEN at2.blast_date END) bp,
               MAX(CASE WHEN t.product_name LIKE '{like}' THEN at2.last_called_date END) cp,
               MAX(at2.blast_date) ba, MAX(at2.last_called_date) ca
        FROM {HUB}.attendee_tickets at2
        INNER JOIN {HUB}.tickets t ON t.ticket_id = at2.ticket_id
        INNER JOIN {HUB}.customers c ON c.id = t.customer_id
        GROUP BY c.cv_customer_id""")}
    return per_cv, has_contact, first_10x360, elite, dim, touches


class Report:
    def __init__(self):
        self.failures = 0

    def check(self, name, ok, detail=""):
        self.failures += 0 if ok else 1
        print(f"  [{'PASS' if ok else 'FAIL'}] {name}" + (f" -- {detail}" if detail else ""))

    def info(self, name, detail):
        print(f"  [INFO] {name} -- {detail}")


def sample(items, n=5):
    items = sorted(items)
    return ", ".join(items[:n]) + (" ..." if len(items) > n else "")


def mismatches(rows, fn):
    return {r["cv_customer_id"] for r in rows if not fn(r)}


def test_query(name, cfg, baseline, out_dir, rep, test_ref=None):
    print(f"\n=== {name} Tickets{f' @ {test_ref}' if test_ref else ''} ===")
    sql = load_sql(cfg, test_ref)
    rows = run(sql)
    per_cv, has_contact, first_10x360, elite, dim, touches = reference(cfg)
    cvs = [r["cv_customer_id"] for r in rows]
    out = set(cvs)

    rep.check("returns rows", len(rows) > 0, f"{len(rows)} rows")
    rep.check("no NULL cv_customer_id", None not in out)
    dupes = {c for c, n in Counter(cvs).items() if n > 1}
    rep.check("one row per business", not dupes, sample(dupes))

    expected = set(per_cv) & has_contact
    missing, extra = expected - out, out - expected
    rep.check("every business with any ticket for the product (and a contact) is listed, nothing else",
              not missing and not extra,
              f"missing {len(missing)} [{sample(missing)}], extra {len(extra)} [{sample(extra)}]")

    rows = [r for r in rows if r["cv_customer_id"] in per_cv]
    required = ["TM_NoShow", "vertical", "sub_vertical", "last_blast_this_product", "last_blast_all_products",
                "ticket_summary_this_product", "ticket_summary_all_products", "first_10x360_purchase_date"]
    absent = [c for c in required if not rows or c not in rows[0]]
    rep.check("has every ticket-list column", not absent, f"missing: {', '.join(absent)}" if absent else "")
    if absent:
        return

    bad = mismatches(rows, lambda r: all((r[col] or 0) == per_cv[r["cv_customer_id"]]["counts"][st]
                                         for st, col in STATUS_COLS.items()))
    rep.check("status counts match the Hub on every row", not bad, sample(bad))
    bad = mismatches(rows, lambda r: r["ticket_count"] == sum(r[c] or 0 for c in STATUS_COLS.values()))
    rep.check("status counts add up to ticket_count", not bad, sample(bad))
    bad = mismatches(rows, lambda r: r["unscheduled_tickets"] == sum(r[STATUS_COLS[s]] or 0 for s in UNSCHEDULED))
    rep.check("unscheduled_tickets = open + undecided + undecided-at-sale + expired", not bad, sample(bad))

    def group_ok(r):
        ou = (r["TM_Open"] or 0) + (r["TM_Undecided"] or 0) + (r["TM_UndecidedAtSale"] or 0)
        ex = r["TM_Expired"] or 0
        want = ("No Open/Undecided/Expired" if ou + ex == 0 else "Expired Only" if ou == 0
                else "Open/Undecided Only" if ex == 0 else "Open/Undecided + Expired")
        return r["ticket_status_group"] == want
    bad = mismatches(rows, group_ok)
    rep.check("ticket_status_group matches the counts", not bad, sample(bad))

    def dates_ok(r):
        p = per_cv[r["cv_customer_id"]]
        return (as_date(r["first_purchase_date"]) == (min(p["bought"]) if p["bought"] else None)
                and as_date(r["latest_purchase_date"]) == (max(p["bought"]) if p["bought"] else None)
                and as_date(r["next_event_date"]) == (min(p["next"]) if p["next"] else None)
                and as_date(r["last_attended_date"]) == (max(p["attended"]) if p["attended"] else None))
    bad = mismatches(rows, dates_ok)
    rep.check("purchase dates, next event and last attended match the Hub", not bad, sample(bad))

    bad = mismatches(rows, lambda r: as_date(r["first_10x360_purchase_date"]) == first_10x360.get(r["cv_customer_id"])
                     and r["is_10x360_customer"] == ("Yes" if r["cv_customer_id"] in first_10x360 else "No"))
    n10 = sum(1 for r in rows if r["cv_customer_id"] in first_10x360)
    rep.check("10X360 first purchase date matches the DWH on every row", not bad,
              f"{n10} 10X360 customers" + (f"; mismatched: {sample(bad)}" if bad else ""))

    bad = mismatches(rows, lambda r: (r["elite_status"] or None) == elite.get(r["cv_customer_id"]))
    rep.check("elite_status matches DimCustomer.EliteStatus on every row", not bad, sample(bad))

    def vertical_ok(r):
        d = dim.get(r["cv_customer_id"]) or {}
        return (r["vertical"] or None) == (d.get("v") or None) and (r["sub_vertical"] or None) == (d.get("sv") or None)
    bad = mismatches(rows, vertical_ok)
    rep.check("vertical and sub_vertical match DimCustomer on every row", not bad, sample(bad))

    def touch_ok(r):
        t = touches.get(r["cv_customer_id"]) or {}
        return (str(r["last_blast_this_product"]) == str(t.get("bp"))
                and str(r["last_called_this_product"]) == str(t.get("cp"))
                and str(r["last_blast_all_products"]) == str(t.get("ba"))
                and str(r["last_called_all_products"]) == str(t.get("ca")))
    bad = mismatches(rows, touch_ok)
    rep.check("blast and call dates (this product and all products) match the Hub", not bad, sample(bad))

    def summary_ok(r):
        s = r["ticket_summary_this_product"] or ""
        return sum(int(n) for n in re.findall(r" x(\d+)", s)) == r["ticket_count"]
    bad = mismatches(rows, summary_ok)
    rep.check("ticket_summary_this_product adds up to ticket_count", not bad, sample(bad))

    rerun = {r["cv_customer_id"]: (r["contact_source"], r["contact_email"], r["contact_name"], r["contact_phone"])
             for r in run(sql)}
    changed = {r["cv_customer_id"] for r in rows
               if rerun.get(r["cv_customer_id"]) != (r["contact_source"], r["contact_email"], r["contact_name"], r["contact_phone"])}
    rep.check("same contacts on a second run", not changed, sample(changed))

    for col in ["contact_email", "abr", "vertical", "elite_status", "first_purchase_date", "last_blast_this_product"]:
        blank = sum(1 for r in rows if not r.get(col))
        rep.info(f"blank {col}", f"{blank} of {len(rows)} ({blank / len(rows):.0%})")
    groups = Counter(r["ticket_status_group"] for r in rows)
    rep.info("ticket_status_group", ", ".join(f"{k}: {v}" for k, v in sorted(groups.items())))
    rep.info("10X360 customers", f"{n10} of {len(rows)}")

    if baseline:
        old = {r["cv_customer_id"] for r in run(load_sql(cfg, baseline))}
        added, removed = out - old, old - out
        rep.info(f"vs {baseline}", f"{len(old)} -> {len(out)} businesses (+{len(added)} / -{len(removed)})")
        unexplained = {c for c in removed if c in expected}
        rep.check("every removed business has no live ticket or no contact", not unexplained, sample(unexplained))
        path = out_dir / f"diff_{name.replace(' ', '_')}.csv"
        with open(path, "w", newline="", encoding="utf-8") as fh:
            w = csv.writer(fh)
            w.writerow(["cv_customer_id", "change"])
            for c in sorted(removed):
                w.writerow([c, "removed"])
            for c in sorted(added):
                w.writerow([c, "added"])
        rep.info("diff written", str(path))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--baseline", help="git ref to diff the business list against, e.g. HEAD")
    ap.add_argument("--only", choices=list(QUERIES))
    ap.add_argument("--test-ref", help="test a committed version instead of the working copy")
    ap.add_argument("--out", default=str(REPO / "tests" / "output"))
    args = ap.parse_args()
    out_dir = Path(args.out)
    out_dir.mkdir(parents=True, exist_ok=True)
    rep = Report()
    for name, cfg in QUERIES.items():
        if not args.only or args.only == name:
            test_query(name, cfg, args.baseline, out_dir, rep, args.test_ref)
    print(f"\n{'ALL CHECKS PASSED' if rep.failures == 0 else f'{rep.failures} CHECK(S) FAILED'}")
    sys.exit(1 if rep.failures else 0)


if __name__ == "__main__":
    main()
