#!/usr/bin/env python3
"""Inspect the actual Android ELF files; never substitute this for device testing."""
import argparse
import datetime
import hashlib
import json
import pathlib
import struct

SYSTEM_LIBS = {
    "libc.so", "libdl.so", "libm.so", "liblog.so", "libandroid.so",
    "libOpenSLES.so", "libmediandk.so", "libc++_shared.so",
}
RUNTIME_SHA256 = "ab4e6c71b96b851de45a8a9bd86369e7dbc2130a44b3b4520564be94847910f2"

def inspect(path):
    data = path.read_bytes()
    result = {"file": path.name, "size": len(data), "sha256": hashlib.sha256(data).hexdigest()}
    errors = []
    def require(condition, message):
        if not condition:
            errors.append(message)
    require(data[:6] == b"\x7fELF\x02\x01", "Expected little-endian ELF64")
    if errors:
        return result, errors
    header = struct.unpack_from("<16sHHIQQQIHHHHHH", data)
    require(header[1] == 3 and header[2] == 183, "Expected an AArch64 shared library")
    require(header[9] == 56, "Unexpected ELF64 program-header size")
    segments = [struct.unpack_from("<IIQQQQQQ", data, header[5] + i * header[9])
                for i in range(header[10])]
    loads = [segment for segment in segments if segment[0] == 1]
    require(bool(loads), "Missing load segments")
    result["load_segments"] = [
        {"offset": s[2], "virtual_address": s[3], "alignment": s[7], "flags": s[1]}
        for s in loads
    ]
    for segment in loads:
        require(segment[7] >= 16384 and (segment[3] - segment[2]) % 16384 == 0,
                "Load segment does not support 16 KiB alignment")
        require(segment[1] & 3 != 3, "Executable and writable load segment")
        require(segment[2] + segment[5] <= len(data), "Load segment exceeds file")
    stack = [s for s in segments if s[0] == 0x6474e551]
    require(bool(stack) and all(s[1] & 1 == 0 for s in stack), "Missing non-executable stack")
    dynamic = [s for s in segments if s[0] == 2]
    require(len(dynamic) == 1, "Expected one dynamic segment")
    entries = []
    if dynamic:
        segment = dynamic[0]
        for offset in range(segment[2], segment[2] + segment[5], 16):
            entry = struct.unpack_from("<qQ", data, offset)
            if entry[0] == 0:
                break
            entries.append(entry)
    tags = dict(entries)
    def file_offset(address):
        for segment in loads:
            if segment[3] <= address < segment[3] + segment[5]:
                return segment[2] + address - segment[3]
        raise ValueError("Dynamic string table is outside loaded file segments")
    strings_start = file_offset(tags[5])
    strings_end = strings_start + tags[10]
    def string(offset):
        start = strings_start + offset
        if not strings_start <= start < strings_end:
            raise ValueError("Invalid dynamic string offset")
        end = data.index(b"\0", start, strings_end)
        return data[start:end].decode("utf-8")
    result["needed"] = [string(value) for tag, value in entries if tag == 1]
    result["search_paths"] = [string(value) for tag, value in entries if tag in (15, 29)]
    require(not result["search_paths"], "Release library contains an embedded runtime search path")
    require(set(result["needed"]) <= SYSTEM_LIBS, "Unpackaged or unexpected shared-library dependency")
    if path.name == "liblibrustdesk.so":
        require("libc++_shared.so" in result["needed"], "Missing expected C++ runtime dependency")
        require(b"Java_ffi_FFI_" in data, "Missing original Android JNI export namespace")
    else:
        require(result["sha256"] == RUNTIME_SHA256, "NDK r28c C++ runtime hash differs")
    return result, errors

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("native_run", type=pathlib.Path)
    args = parser.parse_args()
    run = args.native_run.resolve()
    report = {
        "checked_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "native_run": str(run), "files": [], "errors": [],
        "verifier_sha256": hashlib.sha256(pathlib.Path(__file__).read_bytes()).hexdigest(),
        "status": "running", "passed": False,
        "scope": "Binary inspection only; Android installation and permissions are not verified.",
    }
    result_file = run / "native-validation.json"
    exit_file = run / "native-validation-exit-code.txt"
    # Invalidate a previous success before parsing any input. A crash stays failed.
    exit_file.write_text("1\n")
    result_file.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    try:
        if (run / "exit-code.txt").read_text().strip() != "0":
            raise ValueError("Native compilation did not complete successfully")
        expected = {}
        for line in (run / "native-output.sha256").read_text().splitlines():
            digest, name = line.split(maxsplit=1)
            expected[name.lstrip("*")] = digest.lower()
        for name in ("liblibrustdesk.so", "libc++_shared.so"):
            try:
                result, errors = inspect(run / name)
                if expected.get(name) != result["sha256"]:
                    errors.append("Native output checksum manifest mismatch")
                report["files"].append(result)
                report["errors"].extend(name + ": " + error for error in errors)
            except (OSError, ValueError, KeyError, IndexError, struct.error) as error:
                report["errors"].append(name + ": " + type(error).__name__ + ": " + str(error))
    except (OSError, ValueError, KeyError, IndexError, struct.error) as error:
        report["errors"].append(type(error).__name__ + ": " + str(error))
    report["status"] = "completed"
    report["passed"] = not report["errors"] and len(report["files"]) == 2
    result_file.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    code = 0 if report["passed"] else 1
    exit_file.write_text(str(code) + "\n")
    print(json.dumps(report, indent=2))
    return code

if __name__ == "__main__":
    raise SystemExit(main())
