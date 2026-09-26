#!/usr/bin/env python3
"""Render candidate Nginx files without installing or reloading them."""
import argparse
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument("--www-port", type=int, required=True)
parser.add_argument("--dashboard-port", type=int, required=True)
parser.add_argument("--api-port", type=int, required=True)
parser.add_argument("--output-dir", type=Path, required=True)
args = parser.parse_args()
ports = {"WWW_PORT": args.www_port, "DASHBOARD_PORT": args.dashboard_port, "API_PORT": args.api_port}
if len(set(ports.values())) != 3 or any(not 1024 < port < 65536 for port in ports.values()):
    parser.error("Use three distinct unprivileged loopback ports")
args.output_dir.mkdir(parents=True, exist_ok=True)
for source, name in [("nginx-site.conf.template", "undersky-core.conf"),
                     ("nginx-model-routes.conf.template", "undersky-core-model-routes.conf"),
                     ("nginx-proxy.conf.template", "undersky-core-proxy.conf")]:
    content = Path(__file__).with_name(source).read_text()
    for key, port in ports.items():
        content = content.replace("{{" + key + "}}", str(port))
    (args.output_dir / name).write_text(content)
print("Rendered candidate site and model-route files; no running configuration changed")
