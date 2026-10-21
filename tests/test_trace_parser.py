import pytest
from app.trace_parser import parse_trace_file, PROCESS_MAP

def test_parse_trace_file(tmp_path):
    trace_content = (
        "task_id\thash\tnative_id\tname\tstatus\texit\trealtime\t%cpu\tpeak_rss\tvpeak\n"
        "1\t4a/b1234\t12345\tQC_FILTERING (sample_1)\tCOMPLETED\t0\t1m 15s\t125.0%\t1.2 GB\t1.5 GB\n"
        "2\t8c/d5678\t12346\tINTEGRATION_CLUSTERING\tCACHED\t0\t4m 30s\t380.0%\t8.4 GB\t9.1 GB\n"
        "3\t9f/e9012\t12347\tTRAJECTORY_MONOCLE3\tFAILED\t1\t30s\t95.0%\t2.1 GB\t2.5 GB\n"
    )
    trace_file = tmp_path / "trace.txt"
    trace_file.write_text(trace_content)

    results = parse_trace_file(trace_file)
    assert len(results) == 3

    t1 = results["01"]
    assert t1["process"] == "QC_FILTERING"
    assert t1["status"] == "COMPLETED"
    assert t1["exit_code"] == 0
    assert t1["duration"] == "1m 15s"
    assert t1["cpu_pct"] == "125.0%"
    assert t1["peak_rss"] == "1.2 GB"

    t3 = results["07"]
    assert t3["process"] == "TRAJECTORY_MONOCLE3"
    assert t3["status"] == "FAILED"
    assert t3["exit_code"] == 1
