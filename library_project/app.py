"""Library Management System: Flask backend.
Every database action goes through MySQL views / stored procedures; Python only
passes parameters (parameterised queries, so no SQL injection)."""
from decimal import Decimal
from datetime import date, datetime
from functools import wraps
from flask import Flask, jsonify, request, session, render_template
from flask.json.provider import DefaultJSONProvider
from werkzeug.security import check_password_hash, generate_password_hash
import mysql.connector
from mysql.connector import pooling
import config

class Provider(DefaultJSONProvider):
    @staticmethod
    def default(o):                       # make MySQL types JSON-friendly
        if isinstance(o, Decimal): return float(o)
        if isinstance(o, (date, datetime)): return o.isoformat(sep=" ") if isinstance(o, datetime) else o.isoformat()
        return DefaultJSONProvider.default(o)

app = Flask(__name__)
app.json = Provider(app)
app.secret_key = config.SECRET_KEY
pool = pooling.MySQLConnectionPool(pool_name="lib", pool_size=8, **config.DB)   # connection pooling

# ------------------------------------------------------------------ helpers
def run(sql, args=(), proc=False, one=False, write=False):
    """Run a query / stored procedure on a pooled connection; returns list of dicts."""
    cnx = pool.get_connection()
    try:
        cur = cnx.cursor(dictionary=True)
        cur.execute("SET @app_user = %s", (session.get("username", "anonymous"),))  # audit trail
        if proc:
            cur.callproc(sql, args)
            rows = [r for res in cur.stored_results() for r in res.fetchall()]
        else:
            cur.execute(sql, args)
            rows = cur.fetchall() if cur.with_rows else []
        cnx.commit()
        return (rows[0] if rows else None) if one else rows
    finally:
        cnx.close()

def api(fn):
    """Wrap a route: JSON errors; SIGNAL messages from MySQL become friendly messages."""
    @wraps(fn)
    def w(*a, **k):
        try:
            return jsonify(fn(*a, **k))
        except mysql.connector.Error as e:
            return jsonify(error=e.msg), 400
        except PermissionError as e:
            return jsonify(error=str(e)), 403
    return w

def need(*roles):
    def deco(fn):
        @wraps(fn)
        def w(*a, **k):
            if "uid" not in session: raise PermissionError("Please log in")
            if roles and session["role"] not in roles: raise PermissionError("Not allowed for your role")
            return fn(*a, **k)
        return w
    return deco

STAFF = ("admin", "librarian")
def body(): return request.get_json(force=True, silent=True) or {}

# ------------------------------------------------------------------ pages
@app.get("/")
def home(): return render_template("index.html")

# ------------------------------------------------------------------ auth
@app.post("/api/login")
@api
def login():
    d = body()
    u = run("SELECT u.user_id, u.username, u.password_hash, r.role_name FROM users u "
            "JOIN roles r ON r.role_id=u.role_id WHERE u.username=%s AND u.is_active", (d.get("username", ""),), one=True)
    if not u or not check_password_hash(u["password_hash"], d.get("password", "")):
        return {"error": "Wrong username or password"}
    session.update(uid=u["user_id"], username=u["username"], role=u["role_name"])
    run("UPDATE users SET last_login=NOW() WHERE user_id=%s", (u["user_id"],))
    return current_user()

@app.post("/api/logout")
@api
def logout():
    session.clear(); return {"ok": True}

def current_user():
    """Plain function (returns a dict) so both /api/login and /api/me can use it."""
    if "uid" not in session: return {"user": None}
    info = run("SELECT member_id AS id, full_name FROM members WHERE user_id=%s", (session["uid"],), one=True) \
        if session["role"] == "student" else \
        run("SELECT staff_id AS id, full_name FROM staff WHERE user_id=%s", (session["uid"],), one=True)
    session["pid"] = info["id"]
    return {"user": {"username": session["username"], "role": session["role"], **info}}

@app.get("/api/me")
@api
def me(): return current_user()

@app.post("/api/register")
@api
def register():
    d = body()
    r = run("sp_register_member", (d["username"], generate_password_hash(d["password"]), d["full_name"],
            d["email"], d.get("phone"), int(d.get("plan_id", 1)), int(d.get("branch_id", 1))), proc=True, one=True)
    return {"member_id": r["member_id"]}

# ------------------------------------------------------------------ catalog
@app.get("/api/books")
@api
@need()
def books():
    g = request.args.get
    q, cat, letter = g("q", "").strip(), g("category", ""), g("letter", "")
    sort = {"title": "title", "author": "authors, title", "newest": "publication_year DESC, title",
            "rating": "avg_rating DESC, review_count DESC", "available": "available_copies DESC, title"}.get(g("sort"), "title")
    page = max(int(g("page", 1)), 1)
    where, args = ["1=1"], []
    if q:
        where.append("(title LIKE %s OR authors LIKE %s OR isbn LIKE %s)"); args += [f"%{q}%"] * 3
    if cat:
        where.append("CONCAT(', ', categories, ', ') LIKE %s"); args.append(f"%, {cat}, %")
    if letter and letter.isalpha():
        where.append("title LIKE %s"); args.append(letter[0] + "%")
    if g("avail") == "1":
        where.append("available_copies > 0")
    w = " AND ".join(where)
    total = run(f"SELECT COUNT(*) n FROM v_book_catalog WHERE {w}", args, one=True)["n"]
    rows = run(f"SELECT * FROM v_book_catalog WHERE {w} ORDER BY {sort} LIMIT %s OFFSET %s",
               args + [config.PAGE_SIZE, (page - 1) * config.PAGE_SIZE])
    return {"rows": rows, "total": total, "page": page, "pages": -(-total // config.PAGE_SIZE)}

@app.get("/api/history")
@api
@need()
def history():
    sql = ("SELECT i.issue_id, bk.title, c.barcode, m.full_name AS member_name, i.issue_date, i.due_date, i.return_date, "
           "i.status, GREATEST(DATEDIFF(COALESCE(i.return_date, CURRENT_DATE), i.due_date), 0) AS days_late "
           "FROM issues i JOIN book_copies c ON c.copy_id=i.copy_id JOIN books bk ON bk.book_id=c.book_id "
           "JOIN members m ON m.member_id=i.member_id ")
    if session["role"] == "student":
        return run(sql + "WHERE i.member_id=%s ORDER BY i.issue_date DESC, i.issue_id DESC LIMIT 100", (session["pid"],))
    return run(sql + "ORDER BY i.issue_date DESC, i.issue_id DESC LIMIT 100")

@app.get("/api/categories")
@api
def categories(): return run("SELECT name FROM categories ORDER BY name")

@app.get("/api/books/<int:bid>/copies")
@api
@need(*STAFF)
def copies(bid):
    return run("SELECT c.copy_id, c.barcode, c.status, br.branch_name, s.shelf_code FROM book_copies c "
               "JOIN shelves s ON s.shelf_id=c.shelf_id JOIN branches br ON br.branch_id=s.branch_id "
               "WHERE c.book_id=%s ORDER BY c.copy_id", (bid,))

@app.get("/api/books/<int:bid>/also")
@api
@need()
def also(bid):   # data-mining view: readers who borrowed this also borrowed ...
    return run("SELECT b.book_id, b.title, a.common_readers FROM v_also_borrowed a "
               "JOIN books b ON b.book_id=a.also_book_id WHERE a.book_id=%s "
               "ORDER BY a.common_readers DESC LIMIT 5", (bid,))

# ------------------------------------------------------------------ circulation
@app.get("/api/loans")
@api
@need()
def loans():
    if session["role"] == "student":
        return run("SELECT * FROM v_active_loans WHERE member_id=%s ORDER BY due_date", (session["pid"],))
    return run("SELECT * FROM v_active_loans ORDER BY days_overdue DESC, due_date")

@app.post("/api/issue")
@api
@need(*STAFF)
def issue():
    d = body()
    return run("sp_issue_book", (int(d["member_id"]), int(d["copy_id"]), session["pid"]), proc=True, one=True)

@app.post("/api/return")
@api
@need(*STAFF)
def ret(): return run("sp_return_book", (int(body()["issue_id"]), session["pid"]), proc=True, one=True)

@app.post("/api/renew")
@api
@need()
def renew(): return run("sp_renew_book", (int(body()["issue_id"]),), proc=True, one=True)

@app.post("/api/reserve")
@api
@need("student")
def reserve(): return run("sp_reserve_book", (int(body()["book_id"]), session["pid"]), proc=True, one=True)

@app.get("/api/reservations")
@api
@need()
def reservations():
    sql = ("SELECT r.reservation_id, b.title, m.full_name, r.reserved_on, r.status, r.expires_on FROM reservations r "
           "JOIN books b ON b.book_id=r.book_id JOIN members m ON m.member_id=r.member_id ")
    if session["role"] == "student":
        return run(sql + "WHERE r.member_id=%s ORDER BY r.reserved_on DESC", (session["pid"],))
    return run(sql + "WHERE r.status IN ('Waiting','Ready') ORDER BY r.reserved_on")

# ------------------------------------------------------------------ borrow / return requests
REQ = ("SELECT r.request_id, r.req_type, r.status, r.requested_on, r.decided_on, r.note, m.full_name, "
       "COALESCE(b1.title, b2.title) AS title FROM circulation_requests r JOIN members m ON m.member_id=r.member_id "
       "LEFT JOIN books b1 ON b1.book_id=r.book_id LEFT JOIN issues i ON i.issue_id=r.issue_id "
       "LEFT JOIN book_copies c ON c.copy_id=i.copy_id LEFT JOIN books b2 ON b2.book_id=c.book_id ")

@app.get("/api/requests")
@api
@need()
def requests_list():
    if session["role"] == "student":
        return run(REQ + "WHERE r.member_id=%s ORDER BY r.requested_on DESC", (session["pid"],))
    return run(REQ + "ORDER BY (r.status='Pending') DESC, r.requested_on DESC LIMIT 100")

@app.post("/api/request/issue")
@api
@need("student")
def request_issue(): return run("sp_request_issue", (session["pid"], int(body()["book_id"])), proc=True, one=True)

@app.post("/api/request/return")
@api
@need("student")
def request_return(): return run("sp_request_return", (session["pid"], int(body()["issue_id"])), proc=True, one=True)

@app.post("/api/requests/<int:rid>/approve")
@api
@need(*STAFF)
def req_approve(rid): run("sp_approve_request", (rid, session["pid"]), proc=True); return {"ok": True}

@app.post("/api/requests/<int:rid>/reject")
@api
@need(*STAFF)
def req_reject(rid): run("sp_reject_request", (rid, session["pid"], body().get("note", "")[:200]), proc=True); return {"ok": True}

@app.post("/api/requests/<int:rid>/cancel")
@api
@need("student")
def req_cancel(rid): run("sp_cancel_request", (rid, session["pid"]), proc=True); return {"ok": True}

# ------------------------------------------------------------------ fines
@app.get("/api/fines")
@api
@need()
def fines():
    if session["role"] == "student":
        return run("SELECT * FROM v_fine_details WHERE member_id=%s ORDER BY assessed_on DESC", (session["pid"],))
    return run("SELECT * FROM v_fine_details ORDER BY status, assessed_on DESC")

@app.post("/api/pay")
@api
@need(*STAFF)
def pay():
    d = body()
    return run("sp_pay_fine", (int(d["fine_id"]), Decimal(str(d["amount"])), d.get("method", "Cash"), session["pid"]),
               proc=True, one=True)

# ------------------------------------------------------------------ staff pages
@app.get("/api/members")
@api
@need(*STAFF)
def members():
    q = f"%{request.args.get('q', '')}%"
    return run("SELECT * FROM v_member_summary WHERE full_name LIKE %s OR email LIKE %s ORDER BY full_name", (q, q))

@app.get("/api/dashboard")
@api
@need(*STAFF)
def dashboard():
    one = lambda s: run(s, one=True)
    return {
        "totals": one("SELECT (SELECT COUNT(*) FROM books) books, (SELECT COUNT(*) FROM book_copies) copies, "
                      "(SELECT COUNT(*) FROM members WHERE status='Active') members, "
                      "(SELECT COUNT(*) FROM v_active_loans) active_loans, "
                      "(SELECT COUNT(*) FROM v_overdue_loans) overdue, "
                      "(SELECT IFNULL(SUM(outstanding),0) FROM v_fine_details WHERE status='Unpaid') unpaid_fines"),
        "popular": run("SELECT title, total_loans FROM v_popular_books ORDER BY total_loans DESC LIMIT 6"),
        "branches": run("SELECT * FROM v_branch_inventory"),
        "recent": run("SELECT log_id, table_name, action, details, changed_by, changed_at FROM audit_log "
                      "ORDER BY log_id DESC LIMIT 8"),
    }

if __name__ == "__main__":
    app.run(debug=True)
