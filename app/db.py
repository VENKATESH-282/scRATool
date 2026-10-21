import sqlite3
import json
from datetime import datetime
from typing import Optional, Dict, Any, List
from .config import DB_PATH

def get_connection():
    conn = sqlite3.connect(str(DB_PATH))
    conn.row_factory = sqlite3.Row
    return conn

def init_db():
    conn = get_connection()
    cursor = conn.cursor()
    cursor.execute("""
    CREATE TABLE IF NOT EXISTS runs (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        profile TEXT DEFAULT 'local,pixi',
        resume INTEGER DEFAULT 1,
        stub_run INTEGER DEFAULT 0,
        status TEXT DEFAULT 'PENDING',
        start_time TEXT,
        end_time TEXT,
        duration TEXT,
        exit_code INTEGER,
        pid INTEGER,
        params_json TEXT,
        command TEXT,
        outdir TEXT,
        created_at TEXT,
        session_token TEXT
    )
    """)
    # Check if session_token and new remote columns exist in runs
    cursor.execute("PRAGMA table_info(runs)")
    cols = [row["name"] for row in cursor.fetchall()]
    if "session_token" not in cols:
        cursor.execute("ALTER TABLE runs ADD COLUMN session_token TEXT")
    if "is_remote" not in cols:
        cursor.execute("ALTER TABLE runs ADD COLUMN is_remote INTEGER DEFAULT 0")
    if "remote_host" not in cols:
        cursor.execute("ALTER TABLE runs ADD COLUMN remote_host TEXT")
    if "remote_user" not in cols:
        cursor.execute("ALTER TABLE runs ADD COLUMN remote_user TEXT")
    if "remote_dir" not in cols:
        cursor.execute("ALTER TABLE runs ADD COLUMN remote_dir TEXT")
    if "remote_pid" not in cols:
        cursor.execute("ALTER TABLE runs ADD COLUMN remote_pid INTEGER")


    cursor.execute("""
    CREATE TABLE IF NOT EXISTS sessions (
        token TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        created_at TEXT NOT NULL,
        last_accessed TEXT NOT NULL,
        status TEXT DEFAULT 'ACTIVE'
    )
    """)
    cursor.execute("""
    CREATE TABLE IF NOT EXISTS cluster_profiles (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL,
        host TEXT NOT NULL,
        user TEXT NOT NULL,
        port INTEGER DEFAULT 22,
        auth_method TEXT DEFAULT 'password',
        password TEXT,
        private_key_path TEXT,
        is_default INTEGER DEFAULT 0
    )
    """)
    conn.commit()
    conn.close()

def create_session_db(token: str, name: str, created_at: str, last_accessed: str, status: str = "ACTIVE"):
    conn = get_connection()
    cursor = conn.cursor()
    cursor.execute("""
    INSERT OR REPLACE INTO sessions (token, name, created_at, last_accessed, status)
    VALUES (?, ?, ?, ?, ?)
    """, (token, name, created_at, last_accessed, status))
    conn.commit()
    conn.close()

def update_session_access(token: str, last_accessed: str):
    conn = get_connection()
    cursor = conn.cursor()
    cursor.execute("UPDATE sessions SET last_accessed = ? WHERE token = ?", (last_accessed, token))
    conn.commit()
    conn.close()

def update_session_name(token: str, name: str):
    conn = get_connection()
    cursor = conn.cursor()
    cursor.execute("UPDATE sessions SET name = ? WHERE token = ?", (name, token))
    conn.commit()
    conn.close()

def get_session_db(token: str) -> Optional[Dict[str, Any]]:
    conn = get_connection()
    cursor = conn.cursor()
    cursor.execute("SELECT * FROM sessions WHERE token = ?", (token,))
    row = cursor.fetchone()
    conn.close()
    return dict(row) if row else None

def list_sessions_db() -> List[Dict[str, Any]]:
    conn = get_connection()
    cursor = conn.cursor()
    cursor.execute("SELECT * FROM sessions ORDER BY last_accessed DESC")
    rows = cursor.fetchall()
    conn.close()
    return [dict(r) for r in rows]

def delete_session_db(token: str):
    conn = get_connection()
    cursor = conn.cursor()
    cursor.execute("DELETE FROM sessions WHERE token = ?", (token,))
    conn.commit()
    conn.close()

def create_run(run_id: str, name: str, profile: str, resume: bool, stub_run: bool,
               params: Dict[str, Any], command: str, outdir: str,
               session_token: Optional[str] = None,
               is_remote: bool = False, remote_host: Optional[str] = None,
               remote_user: Optional[str] = None, remote_dir: Optional[str] = None,
               remote_pid: Optional[int] = None) -> Dict[str, Any]:
    conn = get_connection()
    cursor = conn.cursor()
    now = datetime.now().isoformat()
    cursor.execute("""
    INSERT INTO runs (
        id, name, profile, resume, stub_run, status, start_time,
        params_json, command, outdir, created_at, session_token,
        is_remote, remote_host, remote_user, remote_dir, remote_pid
    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    """, (
        run_id, name, profile, 1 if resume else 0, 1 if stub_run else 0,
        "RUNNING", now, json.dumps(params, indent=2), command, outdir, now, session_token,
        1 if is_remote else 0, remote_host, remote_user, remote_dir, remote_pid
    ))
    conn.commit()
    conn.close()
    return get_run(run_id)

def update_run(run_id: str, **kwargs):
    conn = get_connection()
    cursor = conn.cursor()
    fields = []
    values = []
    for k, v in kwargs.items():
        fields.append(f"{k} = ?")
        values.append(v)
    values.append(run_id)
    query = f"UPDATE runs SET {', '.join(fields)} WHERE id = ?"
    cursor.execute(query, values)
    conn.commit()
    conn.close()

def get_run(run_id: str) -> Optional[Dict[str, Any]]:
    conn = get_connection()
    cursor = conn.cursor()
    cursor.execute("SELECT * FROM runs WHERE id = ?", (run_id,))
    row = cursor.fetchone()
    conn.close()
    if row:
        d = dict(row)
        if d.get("params_json"):
            try:
                d["params"] = json.loads(d["params_json"])
            except Exception:
                d["params"] = {}
        return d
    return None

def list_runs(limit: int = 50, session_token: Optional[str] = None) -> List[Dict[str, Any]]:
    conn = get_connection()
    cursor = conn.cursor()
    if session_token:
        cursor.execute("SELECT * FROM runs WHERE session_token = ? ORDER BY created_at DESC LIMIT ?", (session_token, limit))
    else:
        cursor.execute("SELECT * FROM runs ORDER BY created_at DESC LIMIT ?", (limit,))
    rows = cursor.fetchall()
    conn.close()
    results = []
    for r in rows:
        d = dict(r)
        if d.get("params_json"):
            try:
                d["params"] = json.loads(d["params_json"])
            except Exception:
                d["params"] = {}
        results.append(d)
    return results

def delete_run(run_id: str):
    conn = get_connection()
    cursor = conn.cursor()
    cursor.execute("DELETE FROM runs WHERE id = ?", (run_id,))
    conn.commit()
    conn.close()

def list_cluster_profiles() -> List[Dict[str, Any]]:
    conn = get_connection()
    cursor = conn.cursor()
    cursor.execute("SELECT * FROM cluster_profiles ORDER BY name ASC")
    rows = cursor.fetchall()
    conn.close()
    return [dict(r) for r in rows]

def get_cluster_profile(profile_id: int) -> Optional[Dict[str, Any]]:
    conn = get_connection()
    cursor = conn.cursor()
    cursor.execute("SELECT * FROM cluster_profiles WHERE id = ?", (profile_id,))
    row = cursor.fetchone()
    conn.close()
    return dict(row) if row else None

def create_cluster_profile(name: str, host: str, user: str, port: int = 22, auth_method: str = "password", password: Optional[str] = None, private_key_path: Optional[str] = None, is_default: bool = False) -> int:
    conn = get_connection()
    cursor = conn.cursor()
    if is_default:
        cursor.execute("UPDATE cluster_profiles SET is_default = 0")
    cursor.execute("""
    INSERT INTO cluster_profiles (name, host, user, port, auth_method, password, private_key_path, is_default)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
    """, (name, host, user, port, auth_method, password, private_key_path, 1 if is_default else 0))
    profile_id = cursor.lastrowid
    conn.commit()
    conn.close()
    return profile_id

def update_cluster_profile(profile_id: int, **kwargs):
    conn = get_connection()
    cursor = conn.cursor()
    if kwargs.get('is_default'):
        cursor.execute("UPDATE cluster_profiles SET is_default = 0")
    fields = []
    values = []
    for k, v in kwargs.items():
        fields.append(f"{k} = ?")
        values.append(v)
    values.append(profile_id)
    query = f"UPDATE cluster_profiles SET {', '.join(fields)} WHERE id = ?"
    cursor.execute(query, values)
    conn.commit()
    conn.close()

def delete_cluster_profile(profile_id: int):
    conn = get_connection()
    cursor = conn.cursor()
    cursor.execute("DELETE FROM cluster_profiles WHERE id = ?", (profile_id,))
    conn.commit()
    conn.close()
