#!/usr/bin/env python3
import html
from pathlib import Path
import re
import sys


def render(template, company, scheme, port, erp, cloud, mail, fluxer):
    suffix = "" if (scheme, port) in {("https", "443"), ("http", "80")} else f":{port}"
    services = [(erp, "ERPNext - Business"), (cloud, "Nextcloud - Files"),
                (mail, "Postal - Mail administration")]
    if fluxer:
        services.append((fluxer, "Fluxer - Chat and calls"))
    links = "\n".join(
        f'        <li><a href="{html.escape(f"{scheme}://{host}{suffix}/", quote=True)}">'
        f'{html.escape(label)}</a></li>' for host, label in services
    )
    replacements = {"COMPANY": html.escape(company, quote=True), "SERVICES": links}
    # Replace template tokens once, so company names cannot become template markup.
    return re.sub(r"\{\{(COMPANY|SERVICES)\}\}", lambda match: replacements[match[1]], template)


if __name__ == "__main__":
    template = Path(sys.argv[1]).read_text()
    print(render(template, *sys.argv[2:]), end="")
