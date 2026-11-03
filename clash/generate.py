#!/usr/bin/env python3
"""Render a usable Clash config from the template.

Usage:
  python3 clash/generate.py \
    --xhttp-host 10000-<machine-id>.instabox.tech \
    --ws-host 10001-<machine-id>.instabox.tech \
    --uuid <uuid-from-the-machine> \
    --out clash.yaml

The generated file contains the node's UUID, so keep it private:
do not commit it, do not publish it, do not share it publicly.
"""
import argparse
import pathlib
import sys


def main() -> int:
    parser = argparse.ArgumentParser(description="Render Clash config for instabox-vpn")
    parser.add_argument("--xhttp-host", required=True, help="Public host for port 10000")
    parser.add_argument("--ws-host", required=True, help="Public host for port 10001")
    parser.add_argument("--uuid", required=True, help="VLESS UUID from /data/xray/uuid.txt")
    parser.add_argument(
        "--template",
        default=str(pathlib.Path(__file__).parent / "template.yaml"),
        help="Template file to render",
    )
    parser.add_argument("--out", required=True, help="Output Clash yaml path")
    args = parser.parse_args()

    template = pathlib.Path(args.template).read_text(encoding="utf-8")
    rendered = (
        template.replace("__XHTTP_HOST__", args.xhttp_host)
        .replace("__WS_HOST__", args.ws_host)
        .replace("__UUID__", args.uuid)
    )
    if "__" in rendered and ("__XHTTP_HOST__" in rendered or "__WS_HOST__" in rendered or "__UUID__" in rendered):
        print("error: placeholders remain in rendered output", file=sys.stderr)
        return 2

    out = pathlib.Path(args.out)
    out.write_text(rendered, encoding="utf-8")
    # 生成文件里是明文 UUID：权限收紧到本人可读，和 uuid.txt 的 600 对齐。
    # Windows 上 chmod 语义有限，失败也不中断，文件本身已经写好了。
    try:
        out.chmod(0o600)
    except OSError:
        pass
    print(f"Wrote {out} (xhttp={args.xhttp_host}, ws={args.ws_host})")
    print("Permissions set to 600 where supported (the file contains the node UUID, keep it private)")
    print("Validate with: mihomo -t -f " + str(out))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
