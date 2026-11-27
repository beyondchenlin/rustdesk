#!/usr/bin/env python3
"""Verify a validation APK using the pinned Android tools and actual ZIP/ELF bytes."""
import argparse
import datetime
import hashlib
import json
import pathlib
import re
import struct
import subprocess
import zipfile

def elf_info(data):
    if data[:6] != b"\x7fELF\x02\x01":
        raise ValueError("Expected little-endian ELF64")
    header = struct.unpack_from("<16sHHIQQQIHHHHHH", data)
    if header[1] != 3 or header[2] != 183 or header[9] != 56:
        raise ValueError("Expected an AArch64 shared library")
    segments = [struct.unpack_from("<IIQQQQQQ", data, header[5] + i * 56)
                for i in range(header[10])]
    loads = [segment for segment in segments if segment[0] == 1]
    if not loads:
        raise ValueError("Missing load segments")
    for segment in loads:
        if segment[7] < 16384 or (segment[3] - segment[2]) % 16384:
            raise ValueError("Load segment is not 16 KiB compatible")
        if segment[1] & 3 == 3:
            raise ValueError("Writable executable load segment")
    dynamic = [segment for segment in segments if segment[0] == 2]
    entries = []
    for segment in dynamic:
        for offset in range(segment[2], segment[2] + segment[5], 16):
            tag, value = struct.unpack_from("<qQ", data, offset)
            if tag == 0:
                break
            entries.append((tag, value))
    if any(tag in (15, 29) for tag, _ in entries):
        raise ValueError("Packaged library contains an embedded runtime search path")
    return {"size": len(data), "sha256": hashlib.sha256(data).hexdigest(),
            "load_alignment": [segment[7] for segment in loads]}

def unsigned_layout(archive, data):
    """Reject signature structures and unexplained data, including damaged block magic."""
    signature_files = [name for name in archive.namelist()
                       if re.fullmatch(r"META-INF/[^/]+\.(SF|RSA|DSA|EC)", name, re.IGNORECASE)]
    central = archive.start_dir
    ends = []
    for item in archive.infolist():
        offset = item.header_offset
        if data[offset:offset + 4] != b"PK\x03\x04":
            raise ValueError("Invalid local ZIP header")
        flags = struct.unpack_from("<H", data, offset + 6)[0]
        name_len, extra_len = struct.unpack_from("<HH", data, offset + 26)
        end = offset + 30 + name_len + extra_len + item.compress_size
        if flags & 8:
            if data[end:end + 4] == b"PK\x07\x08":
                end += 4
            local_sizes = struct.unpack_from("<II", data, offset + 18)
            zip64 = (0xffffffff in local_sizes or item.file_size >= 0xffffffff
                     or item.compress_size >= 0xffffffff)
            fmt = "<IQQ" if zip64 else "<III"
            crc, compressed, uncompressed = struct.unpack_from(fmt, data, end)
            if (crc, compressed, uncompressed) != (item.CRC, item.compress_size, item.file_size):
                raise ValueError("Invalid ZIP data descriptor")
            end += struct.calcsize(fmt)
        ends.append(end)
    last_end = max(ends, default=0)
    if last_end > central:
        raise ValueError("ZIP payload overlaps its central directory")
    signing_footer = central >= 24 and data[central - 16:central] == b"APK Sig Block 42"
    return {"v1_signature_files": signature_files, "apk_signing_block_footer": signing_footer,
            "unexplained_pre_directory_bytes": central - last_end}

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("apk", type=pathlib.Path)
    parser.add_argument("source", type=pathlib.Path)
    parser.add_argument("--mode", choices=("debug", "unsigned-release"), required=True)
    parser.add_argument("--sdk", type=pathlib.Path, default=pathlib.Path("/mnt/d/demo2/bk-remote-android-sdk"))
    args = parser.parse_args()
    apk, source = args.apk.resolve(), args.source.resolve()
    run = apk.parent / ("inspection-" + datetime.datetime.now().strftime("%Y%m%d-%H%M%S"))
    run.mkdir()
    apk_bytes = apk.read_bytes()
    report = {"apk": str(apk), "mode": args.mode, "formal_release": False,
              "checked_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
              "verifier_sha256": hashlib.sha256(pathlib.Path(__file__).read_bytes()).hexdigest(),
              "sha256": hashlib.sha256(apk_bytes).hexdigest(),
              "size": apk.stat().st_size, "errors": [], "native_libraries": {},
              "installation_verified": False, "upgrade_verified": False}
    def require(condition, message):
        if not condition:
            report["errors"].append(message)
    tools = args.sdk / "build-tools" / "35.0.0"
    def command(name, executable, *arguments):
        process = subprocess.run([str(tools / executable), *map(str, arguments)],
                                 stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                 text=True, timeout=90)
        (run / (name + ".txt")).write_text(process.stdout, encoding="utf-8")
        return process
    badging = command("badging", "aapt", "dump", "badging", apk)
    permissions = command("permissions", "aapt", "dump", "permissions", apk)
    manifest = command("manifest", "aapt", "dump", "xmltree", apk, "AndroidManifest.xml")
    aligned = command("zipalign", "zipalign", "-c", "-P", "16", "-v", "4", apk)
    signed = command("signature", "apksigner", "verify", "--verbose", "--print-certs", apk)
    require(badging.returncode == 0 and permissions.returncode == 0 and manifest.returncode == 0,
            "Android package metadata tool failed")
    require(aligned.returncode == 0, "APK ZIP alignment check failed")
    report["signature_verified"] = signed.returncode == 0
    if args.mode == "debug":
        require(signed.returncode == 0 and "CN=Android Debug" in signed.stdout,
                "Expected a verified development signature")
    else:
        require(signed.returncode != 0 and "DOES NOT VERIFY" in signed.stdout,
                "Expected an explicitly unsigned release validation artifact")
    package = re.search(r"^package: name='([^']+)' versionCode='([^']+)' versionName='([^']+)'",
                        badging.stdout, re.MULTILINE)
    require(package is not None, "Missing package identity")
    if package:
        report.update(package=package[1], version_code=package[2], version_name=package[3])
        require(package[1] == "com.bkremote.client", "Wrong application identifier")
        require(package[3] == "1.5.3", "Wrong release version")
        # Flutter 3.24.5 assigns arm64 split code = 2*1000 + pubspec build number 71.
        require(package[2] == "2071", "Unexpected architecture-specific version code")
    require("sdkVersion:'22'" in badging.stdout, "Unexpected minimum Android SDK")
    require("targetSdkVersion:'36'" in badging.stdout, "Unexpected target Android SDK")
    require("application-label:'BK Remote'" in badging.stdout, "Wrong application brand")
    require("launchable-activity: name='com.carriez.flutter_hbb.MainActivity'" in badging.stdout,
            "Original Kotlin/JNI activity namespace was not preserved")
    require(("application-debuggable" in badging.stdout) == (args.mode == "debug"),
            "Unexpected debuggable state")
    require('bkremote' in manifest.stdout and 'BkProfileRestartActivity' in manifest.stdout,
            "Missing product URI or profile-restart activity")
    for permission in ("INTERNET", "FOREGROUND_SERVICE", "FOREGROUND_SERVICE_MEDIA_PROJECTION",
                       "FOREGROUND_SERVICE_MICROPHONE", "FOREGROUND_SERVICE_SPECIAL_USE",
                       "RECORD_AUDIO", "RECEIVE_BOOT_COMPLETED", "SYSTEM_ALERT_WINDOW"):
        require("android.permission." + permission in permissions.stdout,
                "Missing upstream permission: " + permission)
    with zipfile.ZipFile(apk) as archive:
        if args.mode == "unsigned-release":
            try:
                structures = unsigned_layout(archive, apk_bytes)
                report["signature_structures"] = structures
                require(not structures["v1_signature_files"]
                        and not structures["apk_signing_block_footer"]
                        and structures["unexplained_pre_directory_bytes"] == 0,
                        "A failed signature or unexplained signing region is not an unsigned APK")
            except (ValueError, IndexError, struct.error) as error:
                report["errors"].append("Cannot establish unsigned APK layout: " + str(error))
        names = archive.namelist()
        require(len(names) == len(set(names)), "Duplicate archive entry")
        libraries = [name for name in names if name.startswith("lib/") and name.endswith(".so")]
        required = {"lib/arm64-v8a/librustdesk.so", "lib/arm64-v8a/libc++_shared.so",
                    "lib/arm64-v8a/libflutter.so"}
        if args.mode == "unsigned-release":
            required.add("lib/arm64-v8a/libapp.so")
        require(required <= set(libraries), "Missing required native library")
        for name in libraries:
            require(name.startswith("lib/arm64-v8a/"), "Unexpected native architecture: " + name)
            try:
                report["native_libraries"][name] = elf_info(archive.read(name))
            except (ValueError, struct.error, IndexError) as error:
                report["errors"].append(name + ": " + str(error))
        icon = "assets/flutter_assets/assets/icon.png"
        require(icon in names, "Missing official Flutter brand asset")
        if icon in names:
            actual = hashlib.sha256(archive.read(icon)).hexdigest()
            expected = hashlib.sha256((source / "flutter/assets/icon.png").read_bytes()).hexdigest()
            report["brand_asset_sha256"] = actual
            require(actual == expected, "Packaged brand differs from the frozen official derivative")
        report["archive_entries"] = len(names)
    report["validation_checks_passed"] = not report["errors"]
    (run / "result.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    (run / "exit-code.txt").write_text(("0" if report["validation_checks_passed"] else "1") + "\n")
    print(json.dumps(report, indent=2))
    print("EVIDENCE=" + str(run))
    return 0 if report["validation_checks_passed"] else 1

if __name__ == "__main__":
    raise SystemExit(main())
