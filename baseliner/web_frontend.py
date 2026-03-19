#!/usr/bin/env python3
import streamlit as st
import requests
import pandas as pd
import time

API = "http://localhost:7170"

st.set_page_config(page_title="Baseliner", layout="wide")

st.title("🛰️ Baseliner Recon Console")

# ---------------------------
# GOWITNESS CONTROLS
# ---------------------------
col1, col2 = st.columns(2)

with col1:
    if st.button("Start Gowitness Server"):
        r = requests.post(f"{API}/gowitness/start")
        if r.status_code == 200:
            st.success("Gowitness started (or already running)")
        else:
            st.error("Failed to start Gowitness")

with col2:
    st.markdown("[🌐 Open Gowitness UI](http://localhost:7171)")

st.divider()

# ---------------------------
# SCAN FORM
# ---------------------------
st.subheader("Start Scan")

target = st.text_input("Target (IP or domain)")

if st.button("Submit Scan"):
    if target:
        r = requests.post(f"{API}/scan", json={"target": target})
        if r.status_code == 200:
            st.success(f"Job submitted: {r.json()['job_id']}")
        else:
            st.error(r.text)
    else:
        st.warning("Enter a target")

st.divider()

# ---------------------------
# JOB TABLE
# ---------------------------
st.subheader("Jobs")

def status_badge(status):
    if status == "completed":
        return "🟢 completed"
    elif status == "running":
        return "🟠 running"
    elif status == "failed":
        return "🔴 failed"
    return "⚪ queued"


def load_jobs():
    try:
        r = requests.get(f"{API}/jobs")
        return r.json()
    except:
        return {}


jobs = load_jobs()

rows = []

for job_id, job in jobs.items():
    artifacts = job.get("artifacts", {})

    report_link = artifacts.get("report", "")
    nmap_link = artifacts.get("nmap", "")
    httpx_link = artifacts.get("httpx", "")

    rows.append({
        "Job ID": job_id,
        "Target": job.get("target"),
        "Status": status_badge(job.get("status")),
        "Phase": job.get("phase"),
        "Report": report_link,
        "Nmap": nmap_link,
        "HTTPX": httpx_link,
    })

if rows:
    df = pd.DataFrame(rows)

    st.dataframe(df, use_container_width=True)

    # clickable links
    for row in rows:
        if row["Report"]:
            st.markdown(
                f"🔎 **{row['Job ID']}** → "
                f"[Report]({API}{row['Report']}) | "
                f"[Nmap]({API}{row['Nmap']}) | "
                f"[HTTPX]({API}{row['HTTPX']})"
            )
else:
    st.info("No jobs yet")

st.divider()

# ---------------------------
# JOB DETAILS
# ---------------------------
st.subheader("Job Details")

job_ids = list(jobs.keys())

if job_ids:
    selected = st.selectbox("Select Job", job_ids)

    job = jobs[selected]

    st.write("### Status")
    st.json(job)

    report_url = f"{API}/data/{selected}_report.json"

    try:
        r = requests.get(report_url)
        if r.status_code == 200:
            report = r.json()

            st.write("### Summary")
            st.json(report["summary"])

            st.write("### Top Suspicious Hosts")
            st.dataframe(report["hosts"][:20], use_container_width=True)

    except:
        st.info("Report not ready yet")

# ---------------------------
# AUTO REFRESH
# ---------------------------
st.caption("Auto-refreshing every 5 seconds...")
time.sleep(5)
st.rerun()
