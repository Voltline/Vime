"""Run VimeLanguageModelBenchmarkTests for each LM variant in separate test processes.

Uses an existing optimized build-for-testing `.xctestrun`. Variants alternate per
round so drift affects both equally. Writes raw reports and a run record; it does
not interpret Mac, simulator and device numbers as interchangeable.
"""
import argparse
import json
import os
import subprocess
import time
from pathlib import Path


def run(xctestrun, destination, variant, output, label):
    log = output / f"{label}.log"
    command = ["xcodebuild", "test-without-building", "-xctestrun", str(xctestrun), "-destination", destination,
               "-only-testing:VimeKeyboardTests/VimeLanguageModelBenchmarkTests/testDeviceLatencyAndMemory",
               "-resultBundlePath", str(output / f"{label}.xcresult")]
    env_overrides = {"TEST_RUNNER_VIME_LM_BENCHMARK": "1", "TEST_RUNNER_VIME_LM_VARIANT": variant}
    started = time.time()
    with log.open("w") as stream:
        result = subprocess.run(command, stdout=stream, stderr=subprocess.STDOUT,
                                env={**os.environ, **env_overrides})
    text = log.read_text(errors="replace")
    reports = [json.loads(line.split("VIME_LM_BENCHMARK ", 1)[1]) for line in text.splitlines()
               if "VIME_LM_BENCHMARK {" in line]
    return {"label": label, "variant": variant, "exit": result.returncode, "seconds": time.time() - started,
            "passed": "** TEST EXECUTE SUCCEEDED **" in text or "Test Suite 'Selected tests' passed" in text,
            "report": reports[-1] if reports else None}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--xctestrun", type=Path, required=True)
    parser.add_argument("--destination", required=True)
    parser.add_argument("--rounds", type=int, default=3)
    parser.add_argument("--variants", default="v21,v42")
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    if args.output.exists():
        parser.error("Fresh output directory required.")
    args.output.mkdir(parents=True)
    records = []
    for index in range(args.rounds):
        variants = args.variants.split(",")
        for variant in (variants if index % 2 == 0 else variants[::-1]):
            record = run(args.xctestrun, args.destination, variant, args.output, f"round{index}-{variant}")
            records.append(record)
            print(json.dumps({k: record[k] for k in ("label", "exit", "passed")}), flush=True)
    xcode = subprocess.run(["xcodebuild", "-version"], capture_output=True, text=True).stdout.strip()
    (args.output / "runs.json").write_text(json.dumps({"format": "vime_lm_variant_benchmark_v1",
        "destination": args.destination, "xctestrun": str(args.xctestrun), "xcode": xcode,
        "rounds": args.rounds, "order": "variants alternate per round; one test process per run",
        "runs": records}, ensure_ascii=False, indent=1) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
