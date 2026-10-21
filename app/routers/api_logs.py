import time
import asyncio
from pathlib import Path
from fastapi import APIRouter, HTTPException, Query
from fastapi.responses import StreamingResponse

from ..config import RUNS_DIR
from ..db import get_run

router = APIRouter(prefix="/api/runs", tags=["logs"])

@router.get("/{run_id}/logs")
def get_run_logs(run_id: str, offset: int = Query(0, ge=0)):
    log_file = RUNS_DIR / run_id / "run.log"
    if not log_file.exists():
        return {"lines": [], "next_offset": 0, "completed": False}

    run_record = get_run(run_id)
    is_completed = run_record["status"] in ["COMPLETED", "FAILED", "CANCELLED"] if run_record else False

    try:
        with open(log_file, "r", encoding="utf-8", errors="replace") as f:
            all_lines = f.readlines()

        new_lines = all_lines[offset:]
        return {
            "lines": [line.rstrip("\r\n") for line in new_lines],
            "total_lines": len(all_lines),
            "next_offset": len(all_lines),
            "completed": is_completed
        }
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))

@router.get("/{run_id}/logs/stream")
async def stream_run_logs(run_id: str):
    log_file = RUNS_DIR / run_id / "run.log"

    async def event_generator():
        offset = 0
        max_idle_checks = 60
        idle_count = 0

        while True:
            run_record = get_run(run_id)
            is_done = run_record["status"] in ["COMPLETED", "FAILED", "CANCELLED"] if run_record else False

            if log_file.exists():
                try:
                    with open(log_file, "r", encoding="utf-8", errors="replace") as f:
                        lines = f.readlines()
                    if len(lines) > offset:
                        chunk = lines[offset:]
                        offset = len(lines)
                        for line in chunk:
                            yield f"data: {line.rstrip()}\n\n"
                        idle_count = 0
                    else:
                        idle_count += 1
                except Exception:
                    pass

            if is_done and idle_count > 2:
                yield f"event: done\ndata: {run_record['status']}\n\n"
                break

            await asyncio.sleep(1.0)

    return StreamingResponse(event_generator(), media_type="text/event-stream")
