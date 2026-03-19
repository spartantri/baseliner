#!/usr/bin/env python3
from flask import Flask, request, jsonify, send_file
import subprocess
import os
import uuid
import json
import threading
import queue
import time
import re
from datetime import datetime, UTC

app = Flask(__name__)

DATA_PATH = "/home/ubuntu/data"
SCREEN_PATH = "/home/ubuntu/screens"

os.makedirs(DATA_PATH, exist_ok=True)
os.makedirs(SCREEN_PATH, exist_ok=True)

# ---------------------------
# JOB SYSTEM
# ---------------------------
job_queue = queue.Queue()
jobs = {}

gowitness_process = None

def worker():
    while True:
        job_id, target = job_queue.get()
        try:
            jobs[job_id]["status"] = "running"
            run_pipeline(job_id, target)
            jobs[job_id]["status"] = "completed"
        except Exception as e:
            jobs[job_id]["status"] = "failed"
            jobs[job_id]["error"] = str(e)
        job_queue.task_done()


threading.Thread(target=worker, daemon=True).start()

# ---------------------------
# HELPERS
# ---------------------------
def run(cmd, outfile=None, stdin=None):
    try:
        if outfile:
            with open(outfile, "w") as f:
                subprocess.run(
                    cmd,
                    input=stdin.encode() if stdin else None,
                    stdout=f,
                    stderr=subprocess.PIPE,
                    check=True
                )
        else:
            subprocess.run(
                cmd,
                input=stdin.encode() if stdin else None,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.PIPE,
                check=True
            )
    except subprocess.CalledProcessError as e:
        raise Exception(f"Command failed: {' '.join(cmd)} | {e.stderr.decode(errors='ignore')}")


def valid_target(t):
    return re.match(r"^[a-zA-Z0-9\.\-]+$", t)

# ---------------------------
# GOWITNESS SERVER
# ---------------------------
def start_gowitness_server():
    global gowitness_process

    if gowitness_process and gowitness_process.poll() is None:
        return False
    gowitness_process = subprocess.Popen([
        "gowitness", "report", "server",
        "--db-uri", f"sqlite:///{DATA_PATH}/gowitness.sqlite3",
        "--screenshot-path", SCREEN_PATH,
        "--host", "127.0.0.1",
        "--port", "7171"
    ])
    return True

# ---------------------------
# PIPELINE
# ---------------------------
def run_pipeline(job_id, target):
    base = os.path.join(DATA_PATH, job_id)
    dnsx_out = f"{base}_dnsx.json"
    tlsx_out = f"{base}_tlsx.json"
    nmap_xml = f"{base}_nmap.xml"
    httpx_out = f"{base}_httpx.json"
    report_file = f"{base}_report.json"
    # DNSX
    jobs[job_id]["phase"] = "dnsx"
    run(["dnsx", "-silent", "-json"], dnsx_out, stdin=target)
    # TLSX
    jobs[job_id]["phase"] = "tlsx"
    run(["tlsx", "-silent", "-json", "-host", target], tlsx_out)
    # EXPAND TARGETS
    jobs[job_id]["phase"] = "expand"
    targets = set([target])
    def load_json_lines(path):
        if not os.path.exists(path):
            return []
        with open(path) as f:
            for l in f:
                try:
                    yield json.loads(l)
                except:
                    continue
    for j in load_json_lines(dnsx_out):
        if j.get("host"):
            targets.add(j["host"])
        for ip in j.get("a", []):
            targets.add(ip)
    for j in load_json_lines(tlsx_out):
        if j.get("host"):
            targets.add(j["host"])
    targets = list(targets)
    targets_file = f"{base}_targets.txt"
    with open(targets_file, "w") as f:
        f.write("\n".join(targets))
    # NMAP
    jobs[job_id]["phase"] = "nmap"
    run([
        "nmap", "-iL", targets_file,
        "--top-ports", "1000",
        "-sV", "-T4",
        "-oX", nmap_xml
    ])
    # HTTPX
    jobs[job_id]["phase"] = "httpx"
    run([
        "httpx",
        "-l", targets_file,
        "-json",
        "-title",
        "-tech-detect",
        "-status-code",
        "-favicon",
        "-jarm",
        "-server",
        "-ip",
        "-o", httpx_out
    ])
    # GOWITNESS
    jobs[job_id]["phase"] = "gowitness"
    subprocess.run([
        "gowitness", "scan", "nmap",
        "-f", nmap_xml,
        "--open-only",
        "--threads", "10",
        "--chrome-path", "/usr/bin/chromium-browser",
        "--write-db",
        "--write-db-uri", f"sqlite:///{DATA_PATH}/gowitness.sqlite3",
        "--write-screenshots",
        "--screenshot-path", SCREEN_PATH
    ], check=True)
    # ANALYSIS
    jobs[job_id]["phase"] = "analysis"
    report = build_report(job_id, target, httpx_out)
    with open(report_file, "w") as f:
        json.dump(report, f, indent=2)
    jobs[job_id]["artifacts"] = {
        "report": f"/data/{job_id}_report.json",
        "nmap": f"/data/{job_id}_nmap.xml",
        "httpx": f"/data/{job_id}_httpx.json",
        "gowitness": "http://localhost:7171"
    }
    jobs[job_id]["phase"] = "done"

# ---------------------------
# ANALYSIS / SCORING
# ---------------------------
def score_host(host):
    score = 0
    reasons = []
    if host.get("server"):
        s = host["server"].lower()
        if any(x in s for x in ["cloudflare", "akamai", "fastly"]):
            score += 10
            reasons.append("reverse_proxy")
    if host.get("status") in [401, 403]:
        score += 5
        reasons.append("restricted")
    if not host.get("title"):
        score += 3
        reasons.append("no_title")
    return score, reasons


def build_report(job_id, target, httpx_file):
    hosts = []
    favicon_map = {}
    jarm_map = {}
    with open(httpx_file) as f:
        for l in f:
            try:
                entry = json.loads(l)
            except:
                continue
            host = {
                "url": entry.get("url"),
                "ip": entry.get("ip"),
                "status": entry.get("status-code"),
                "title": entry.get("title"),
                "tech": entry.get("tech"),
                "server": entry.get("webserver"),
                "favicon": entry.get("favicon"),
                "jarm": entry.get("jarm"),
            }
            favicon_map.setdefault(host["favicon"], []).append(host["url"])
            jarm_map.setdefault(host["jarm"], []).append(host["url"])
            hosts.append(host)
    for host in hosts:
        score, reasons = score_host(host)
        if host["favicon"] and len(favicon_map.get(host["favicon"], [])) > 1:
            score += 15
            reasons.append("shared_favicon")
        if host["jarm"] and len(jarm_map.get(host["jarm"], [])) > 1:
            score += 20
            reasons.append("shared_jarm")
        host["score"] = score
        host["reasons"] = reasons
    hosts.sort(key=lambda x: x["score"], reverse=True)
    return {
        "job_id": job_id,
        "target": target,
        "timestamp": datetime.now(UTC).isoformat(),
        "summary": {
            "total_hosts": len(hosts),
            "high_risk": len([h for h in hosts if h["score"] >= 25]),
            "medium_risk": len([h for h in hosts if 10 <= h["score"] < 25]),
        },
        "hosts": hosts[:200]
    }

# ---------------------------
# ROUTES (API ONLY)
# ---------------------------
@app.route("/scan", methods=["POST"])
def scan():
    data = request.get_json()
    target = data.get("target")
    if not target or not valid_target(target):
        return jsonify({"error": "invalid target"}), 400
    job_id = str(uuid.uuid4())[:8]
    jobs[job_id] = {
        "status": "queued",
        "phase": "queued",
        "target": target,
        "created": time.time()
    }
    job_queue.put((job_id, target))
    return jsonify({
        "job_id": job_id,
        "status_url": f"/status/{job_id}"
    })


@app.route("/jobs")
def list_jobs():
    return jsonify(jobs)

@app.route("/status/<job_id>")
def status(job_id):
    return jsonify(jobs.get(job_id, {}))

@app.route("/gowitness/start", methods=["POST"])
def gowitness_start():
    started = start_gowitness_server()
    return jsonify({
        "started": started,
        "url": "http://localhost:7171"
    })

@app.route("/data/<path:filename>")
def download(filename):
    return send_file(os.path.join(DATA_PATH, filename), as_attachment=True)

# ---------------------------
if __name__ == "__main__":
    app.run(host="0.0.0.0", port=7170)
