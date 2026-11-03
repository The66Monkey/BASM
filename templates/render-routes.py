#!/usr/bin/env python3
import json
import sys
from pathlib import Path

import yaml


class UniqueLoader(yaml.SafeLoader):
    pass


def mapping(loader, node, deep=False):
    result = {}
    for key_node, value_node in node.value:
        key = loader.construct_object(key_node, deep=deep)
        if key in result:
            raise ValueError(f"Duplicate YAML key: {key}")
        result[key] = loader.construct_object(value_node, deep=deep)
    return result


UniqueLoader.add_constructor(yaml.resolver.BaseResolver.DEFAULT_MAPPING_TAG, mapping)

if __name__ == "__main__":
    config = yaml.load(sys.stdin, Loader=UniqueLoader)
    domain, port, entrypoint = sys.argv[1:4]
    if domain:
        router = {
            "rule": f"Host(`{domain}`)",
            "service": "fluxer-service",
            "entryPoints": [entrypoint],
        }
        if entrypoint == "websecure":
            router["tls"] = {"certResolver": "letsencrypt"}
        config["http"]["routers"]["fluxer"] = router
        config["http"]["services"]["fluxer-service"] = {
            "loadBalancer": {"servers": [{"url": f"http://host.docker.internal:{port}"}]}
        }
    if len(sys.argv) > 4 and Path(sys.argv[4]).exists():
        with open(sys.argv[4]) as source:
            custom = yaml.load(source, Loader=UniqueLoader)
        if not isinstance(custom, dict) or set(custom) != {"http"} or not isinstance(custom["http"], dict):
            raise ValueError("Custom routes must contain an http mapping only")
        for section, entries in custom["http"].items():
            if section not in {"routers", "services", "middlewares", "serversTransports"} or not isinstance(entries, dict):
                raise ValueError(f"Invalid custom HTTP section: {section}")
            target = config["http"].setdefault(section, {})
            for name, value in entries.items():
                if name in target:
                    raise ValueError(f"Custom route conflicts with managed {section}: {name}")
                if not isinstance(name, str) or not isinstance(value, dict):
                    raise ValueError(f"Invalid custom entry in {section}: {name}")
                target[name] = value
    json.dump(config, sys.stdout, indent=2)
    print()
