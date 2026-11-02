#!/usr/bin/env python3
import json
import sys

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
    domain, port, entrypoint = sys.argv[1:]
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
    json.dump(config, sys.stdout, indent=2)
    print()
