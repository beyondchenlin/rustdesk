#!/usr/bin/env python3
"""Reproduce Android packaging's native symbol stripping without modifying inputs."""
import argparse
import datetime
import hashlib
import json
import pathlib
import subprocess
import zipfile

def sha(data):
    return hashlib.sha256(data).hexdigest()

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('native_run', type=pathlib.Path)
    parser.add_argument('apk', type=pathlib.Path)
    parser.add_argument('--ndk', type=pathlib.Path,
                        default=pathlib.Path('/home/ai/bk-remote-build/android-ndk-r28c'))
    args = parser.parse_args()
    native, apk, ndk = args.native_run.resolve(), args.apk.resolve(), args.ndk.resolve()
    run = apk.parent / ('strip-provenance-' + datetime.datetime.now().strftime('%Y%m%d-%H%M%S'))
    run.mkdir()
    (run / 'exit-code.txt').write_text('1\n')
    tool = ndk / 'toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-strip'
    report = {'time': datetime.datetime.now(datetime.timezone.utc).isoformat(),
              'native_run': str(native), 'apk': str(apk), 'apk_sha256': sha(apk.read_bytes()),
              'strip_tool': str(tool), 'strip_tool_sha256': sha(tool.read_bytes()),
              'items': [], 'errors': [], 'passed': False}
    try:
        if (native / 'exit-code.txt').read_text().strip() != '0':
            raise ValueError('Native build did not succeed')
        with zipfile.ZipFile(apk) as archive:
            for source_name, packaged_name in [('liblibrustdesk.so', 'librustdesk.so'),
                                              ('libc++_shared.so', 'libc++_shared.so')]:
                original = native / source_name
                before = sha(original.read_bytes())
                output = run / packaged_name
                command = [str(tool), '--strip-unneeded', '-o', str(output), str(original)]
                completed = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                           text=True, timeout=60)
                (run / (packaged_name + '.log')).write_text(completed.stdout)
                if completed.returncode != 0:
                    raise ValueError('Pinned strip tool failed: ' + packaged_name)
                actual = archive.read('lib/arm64-v8a/' + packaged_name)
                matched = output.read_bytes() == actual
                preserved = before == sha(original.read_bytes())
                report['items'].append({'source': source_name, 'source_sha256': before,
                                        'packaged': packaged_name, 'packaged_sha256': sha(actual),
                                        'reproduced_sha256': sha(output.read_bytes()),
                                        'exact_bytes_match': matched, 'source_unchanged': preserved,
                                        'command': command})
                if not matched or not preserved:
                    report['errors'].append('Native provenance mismatch: ' + packaged_name)
    except (OSError, ValueError, KeyError, zipfile.BadZipFile, subprocess.TimeoutExpired) as error:
        report['errors'].append(str(error))
    report['passed'] = not report['errors'] and len(report['items']) == 2
    (run / 'result.json').write_text(json.dumps(report, indent=2) + '\n')
    (run / 'exit-code.txt').write_text(('0' if report['passed'] else '1') + '\n')
    print(json.dumps(report, indent=2))
    print('EVIDENCE=' + str(run))
    return 0 if report['passed'] else 1

if __name__ == '__main__':
    raise SystemExit(main())
