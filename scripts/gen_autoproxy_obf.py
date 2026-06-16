#!/usr/bin/env python3
"""Obfuscate the auto-proxy credential list into a XOR+base64 blob.

Input: a plaintext file with one proxy URL per line (blank lines and lines
starting with '#' are ignored). Output (stdout): the obfuscated blob that gets
baked into the app bundle as `autoproxy.dat` by the build phase, and decoded at
runtime in `AutoProxyConstants.swift`.

The XOR key here MUST match `AutoProxy.obfuscationKey` in AutoProxyConstants.swift.

Usage: gen_autoproxy_obf.py <plaintext_file>
"""
import sys
import base64

KEY = b"altchat-autoproxy-obfuscation-key-v1"


def main() -> None:
    if len(sys.argv) < 2:
        sys.exit("usage: gen_autoproxy_obf.py <plaintext_file>")

    urls = []
    with open(sys.argv[1], "r", encoding="utf-8") as handle:
        for line in handle:
            stripped = line.strip()
            if not stripped or stripped.startswith("#"):
                continue
            urls.append(stripped)

    plaintext = "\n".join(urls).encode("utf-8")
    obfuscated = bytes(byte ^ KEY[i % len(KEY)] for i, byte in enumerate(plaintext))
    sys.stdout.write(base64.b64encode(obfuscated).decode("ascii"))


if __name__ == "__main__":
    main()
