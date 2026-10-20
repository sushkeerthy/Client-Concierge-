"""Run the undecided blast query files against Fabric and verify their output.

Each query file is executed exactly as stored. Its output is checked against
reference sets computed independently, keyed on CV customer ID throughout.

Usage:
    python tests/test_blast_queries.py                  # test working copies
    python tests/test_blast_queries.py --baseline HEAD  # also diff vs a git ref
    python tests/test_blast_queries.py --only "Elite Edge"

Requires the deep-dive MCP server checkout (Fabric auth via `az login`).
Set DEEP_DIVE_PATH if it is not at ~/deep-dive.
"""
import argparse
import csv
import os
import re
import subprocess
import sys
from collections import Counter
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
DEEP_DIVE = Path(os.environ.get("DEEP_DIVE_PATH", Path.home() / "deep-dive"))
sys.path.insert(0, str(DEEP_DIVE))
from tools.helpers import connect  # noqa: E402

WORKSPACE, LAKEHOUSE = "Bizops.IT_Data_Gateway.Lakehouse", "IT_Data_Gateway"
HUB, DWH, NS = "IT_Data_Gateway.[10XHub]", "IT_Data_Gateway.DWH", "IT_Data_Gateway.NetSuite"

QUERIES = {
    "10X360":     {"file": "10X360 Undecided Blast.sql",     "like": "%10X360%",     "excl_10x360": False},
    "Essentials": {"file": "Essentials Undecided Blast.sql", "like": "%Essential%",  "excl_10x360": False},
    "Elite Edge": {"file": "Elite Edge Undecided Blast.sql", "like": "%Elite Edge%", "excl_10x360": True},
}

ELITE_MAP = {"3": "ELITE125", "4": "ELITE250", "ELITE125": "ELITE125", "ELITE250": "ELITE250"}


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


def prefix_bare_schemas(sql):
    # Older committed versions used bare [10XHub]/[DWH]/[NetSuite] names
    return re.sub(r"([^.A-Za-z_])\[(10XHub|DWH|NetSuite)\]\.", r"\1IT_Data_Gateway.[\2].", sql)


def load_sql(cfg, ref=None):
    if ref:
        text = subprocess.run(["git", "show", f"{ref}:{cfg['file']}"], cwd=REPO,
                              capture_output=True, text=True, encoding="utf-8", check=True).stdout
        return prefix_bare_schemas(text)
    return (REPO / cfg["file"]).read_text(encoding="utf-8")


def reference_sets(cfg):
    like = cfg["like"]
    ud = f"""
        SELECT t.*, c.cv_customer_id AS cv FROM {HUB}.tickets t
        INNER JOIN {HUB}.customers c ON c.id = t.customer_id
        WHERE t.product_name LIKE '{like}' AND t.status IN ('undecided','open','expired')"""
    refs = {
        "ud": cv_set(f"SELECT DISTINCT cv FROM ({ud}) u"),
        "scheduled": cv_set(f"""
            SELECT DISTINCT c.cv_customer_id AS cv FROM {HUB}.tickets t
            INNER JOIN {HUB}.customers c ON c.id = t.customer_id
            WHERE t.product_name LIKE '{like}' AND t.status IN ('scheduled','reserved')
              AND t.event_date > GETDATE()"""),
        "new_buyer": cv_set(f"""
            SELECT f.CVCustomerID AS cv FROM {DWH}.FactGL f
            INNER JOIN {DWH}.DimProduct dp ON dp.CVProductID = f.CVProductID
            WHERE dp.ProductName LIKE '{like}' AND f.GLLineID != 0 AND f.SalesOrderCashCollected > 0
            GROUP BY f.CVCustomerID HAVING MIN(f.GLDate) >= DATEADD(DAY, -60, GETDATE())"""),
        "refund": cv_set(f"""
            SELECT DISTINCT f.CVCustomerID AS cv FROM {DWH}.FactGL f
            INNER JOIN {DWH}.DimProduct dp ON dp.CVProductID = f.CVProductID
            LEFT JOIN {NS}.silver_Transaction st ON st.TransactionID = CAST(f.GLID AS BIGINT)
            WHERE dp.ProductName LIKE '{like}' AND f.IsGLPosting = 1
              AND (f.GLStatus IN ('Cash Refund : Undefined','Customer Refund : Undefined',
                                  'CCard Refund : Undefined','Credit Memo : Fully Applied')
                   OR (f.GLStatus = 'Credit Memo : Open' AND st.IsClosed = 1))"""),
        "has_contact": cv_set(f"""
            WITH ud AS ({ud})
            SELECT ud.cv FROM ud
            LEFT JOIN {HUB}.transactions tr ON tr.cv_transaction_id = ud.transaction_id
            WHERE (ud.purchaser_email NOT IN ('FabricImport','') AND ud.purchaser_email IS NOT NULL)
               OR (tr.purchaser_email NOT IN ('FabricImport','') AND tr.purchaser_email IS NOT NULL)
            UNION
            SELECT ud.cv FROM ud INNER JOIN {HUB}.attendees a ON a.customer_id = ud.customer_id
            WHERE a.attendee_email IS NOT NULL AND a.attendee_email NOT LIKE '%+placeholder@%'
            UNION
            SELECT ud.cv FROM ud
            INNER JOIN {DWH}.DimCustomer dc ON dc.CVCustomerID = ud.cv
            INNER JOIN {NS}.silver_Entity se ON se.EntityID = dc.NetSuiteID
            WHERE se.Email IS NOT NULL AND se.Email != ''
            UNION
            SELECT ud.cv FROM ud
            INNER JOIN {DWH}.DimCustomerContact dcc ON dcc.Customer = ud.cv
            INNER JOIN {DWH}.DimPerson dp ON dp.CVPersonID = dcc.Person
            WHERE dcc.StaffTitleName = 'Owner' AND dcc.IsActiveName = 'Yes'
              AND dp.Email IS NOT NULL AND dp.Email != ''"""),
    }
    if cfg["excl_10x360"]:
        refs["has_10x360"] = cv_set(f"""
            SELECT c.cv_customer_id AS cv FROM {HUB}.tickets t
            INNER JOIN {HUB}.customers c ON c.id = t.customer_id WHERE t.product_name LIKE '%10X360%'
            UNION
            SELECT f.CVCustomerID FROM {DWH}.FactGL f
            INNER JOIN {DWH}.DimProduct dp ON dp.CVProductID = f.CVProductID
            WHERE dp.ProductName LIKE '%10X360%' AND f.GLLineID != 0 AND f.SalesOrderCashCollected > 0
            UNION
            SELECT dc.CVCustomerID FROM {NS}.silver_Transaction st
            INNER JOIN {DWH}.DimCustomer dc ON dc.NetSuiteID = st.EntityID
            WHERE st.ItemName LIKE '%10X360%'""")
    elite = run(f"""
        SELECT cv, elite FROM (
            SELECT f.CVCustomerID AS cv, f.Elite AS elite,
                   ROW_NUMBER() OVER (PARTITION BY f.CVCustomerID ORDER BY f.GLDate DESC, f.Elite DESC) AS rn
            FROM {DWH}.FactGL f WHERE f.Elite IS NOT NULL AND f.CVCustomerID IS NOT NULL) x
        WHERE rn = 1""")
    refs["elite"] = {r["cv"]: ELITE_MAP.get(str(r["elite"])) for r in elite}
    return refs


EXCLUSIONS = ["scheduled", "new_buyer", "refund", "has_10x360"]


def exclusion_reasons(cv, refs):
    return [k for k in EXCLUSIONS if k in refs and cv in refs[k]]


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


def test_query(name, cfg, baseline, out_dir, rep, test_ref=None):
    print(f"\n=== {name}{f' @ {test_ref}' if test_ref else ''} ===")
    sql = load_sql(cfg, test_ref)
    rows = run(sql)
    refs = reference_sets(cfg)
    cvs = [r["cv_customer_id"] for r in rows]
    out = set(cvs)

    rep.check("returns rows", len(rows) > 0, f"{len(rows)} rows")
    rep.check("no NULL cv_customer_id", None not in out)
    dupes = {c for c, n in Counter(cvs).items() if n > 1}
    rep.check("one row per customer", not dupes, sample(dupes) if dupes else "")

    not_ud = out - refs["ud"]
    rep.check("every row has an open/undecided/expired ticket for the product", not not_ud, sample(not_ud))

    for k in [e for e in EXCLUSIONS if e in refs]:
        leaked = out & refs[k]
        rep.check(f"no '{k}' customers on the list", not leaked, f"{len(leaked)}: {sample(leaked)}" if leaked else "")

    excluded = set().union(*(refs[k] for k in EXCLUSIONS if k in refs))
    expected = (refs["ud"] - excluded) & refs["has_contact"]
    missing, extra = expected - out, out - expected
    rep.check("list matches expected population exactly", not missing and not extra,
              f"missing {len(missing)} [{sample(missing)}], extra {len(extra)} [{sample(extra)}]")

    bad_flag = []
    for r in rows:
        ou, ex = (r["TM_Open"] or 0) + (r["TM_Undecided"] or 0), r["TM_Expired"] or 0
        want = "Expired Only" if ou == 0 else "Open/Undecided Only" if ex == 0 else "Open/Undecided + Expired"
        if r["ticket_status_group"] != want or (ou == 0 and ex == 0):
            bad_flag.append(r["cv_customer_id"])
    rep.check("ticket_status_group matches TM counts", not bad_flag, sample(bad_flag))

    elite_rows = [r for r in rows if refs["elite"].get(r["cv_customer_id"])]
    bad_elite = [r["cv_customer_id"] for r in elite_rows if r["elite_status"] != refs["elite"][r["cv_customer_id"]]]
    rep.check("elite_status matches latest DWH Elite tier", not bad_elite,
              f"compared {len(elite_rows)} rows" + (f"; mismatched: {sample(bad_elite)}" if bad_elite else ""))

    rerun = {r["cv_customer_id"]: (r["contact_source"], r["contact_email"], r["contact_name"], r["contact_phone"])
             for r in run(sql)}
    first = {r["cv_customer_id"]: (r["contact_source"], r["contact_email"], r["contact_name"], r["contact_phone"])
             for r in rows}
    changed = {c for c in first if rerun.get(c) != first[c]}
    rep.check("same contacts on a second run", not changed, sample(changed))

    for col in ["contact_email", "abr", "elite_status"]:
        blank = sum(1 for r in rows if not r.get(col))
        rep.info(f"blank {col}", f"{blank} of {len(rows)} ({blank / len(rows):.0%})")
    groups = {}
    for r in rows:
        groups[r["ticket_status_group"]] = groups.get(r["ticket_status_group"], 0) + 1
    rep.info("ticket_status_group", ", ".join(f"{k}: {v}" for k, v in sorted(groups.items())))

    if baseline:
        old = {r["cv_customer_id"] for r in run(load_sql(cfg, baseline))}
        added, removed = out - old, old - out
        rep.info(f"vs {baseline}", f"{len(old)} -> {len(out)} customers (+{len(added)} / -{len(removed)})")
        unexplained = {c for c in removed if not exclusion_reasons(c, refs)
                       and c in refs["ud"] and c in refs["has_contact"]}
        rep.check("every removed customer has an exclusion reason", not unexplained, sample(unexplained))
        path = out_dir / f"diff_{name.replace(' ', '_')}.csv"
        with open(path, "w", newline="", encoding="utf-8") as fh:
            w = csv.writer(fh)
            w.writerow(["cv_customer_id", "change", "reason"])
            for c in sorted(removed):
                w.writerow([c, "removed", "; ".join(exclusion_reasons(c, refs)) or "no longer eligible"])
            for c in sorted(added):
                w.writerow([c, "added", "eligible; previously excluded via wrong ID match or wider scheduled check"])
        rep.info("diff written", str(path))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--baseline", help="git ref to diff the customer list against, e.g. HEAD")
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
