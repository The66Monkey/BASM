#!/usr/bin/env python3
import html
from pathlib import Path
import re
import sys


def render(template, company, scheme, port, erp, cloud, mail, fluxer, hotdog="",
           lamp_host="", lamp_port="8080", lamp_domain=""):
    suffix = "" if (scheme, port) in {("https", "443"), ("http", "80")} else f":{port}"
    services = [(erp, "ERPNext - Business", "erpnext", "E"),
                (cloud, "Nextcloud - Files", "nextcloud", "N"),
                (mail, "Stalwart - Email", "stalwart", "S")]
    if fluxer:
        services.append((fluxer, "Fluxer - Chat and calls", "fluxer", "F"))
    if hotdog:
        services.append((hotdog, "HotDog CMS - Website", "hotdog", "H"))
    services = [(f"{scheme}://{host}{suffix}/", label, mark, symbol)
                for host, label, mark, symbol in services]
    lamp_access = ""
    if lamp_domain:
        services.append((f"{scheme}://{lamp_domain}{suffix}/", "LAMP - Website", "lamp", "L"))
    elif lamp_host:
        host = "localhost" if lamp_host in {"127.0.0.1", "localhost"} else lamp_host
        services.append((f"http://{host}:{lamp_port}/", "LAMP - Website (private)", "lamp", "L"))
        if host == "localhost":
            command = f"ssh -N -L {lamp_port}:127.0.0.1:{lamp_port} <server-user>@<server-address>"
            lamp_access = (
                '      <section class="note" aria-label="Private LAMP access">\n'
                '        <p>The LAMP link opens the website index on this computer. '
                'From another computer, first open an SSH tunnel to your BASM server '
                'and leave it running:</p>\n'
                f'        <pre><code>{html.escape(command)}</code></pre>\n'
                '        <p>This link does not publish LAMP to the internet '
                'or check whether it is running.</p>\n'
                '      </section>'
            )
    links = "\n".join(
        f'        <li><a class="service-card" href="{html.escape(url, quote=True)}">'
        f'<span class="service-mark mark-{mark}" aria-hidden="true">{symbol}</span>'
        f'<span class="service-name">{html.escape(label)}</span>'
        '<span class="service-arrow" aria-hidden="true">Open</span></a></li>'
        for url, label, mark, symbol in services
    )
    replacements = {"COMPANY": html.escape(company, quote=True), "SERVICES": links,
                    "LAMP_ACCESS": lamp_access}
    # Replace template tokens once, so company names cannot become template markup.
    return re.sub(r"\{\{(COMPANY|SERVICES|LAMP_ACCESS)\}\}", lambda match: replacements[match[1]], template)


if __name__ == "__main__":
    template = Path(sys.argv[1]).read_text()
    print(render(template, *sys.argv[2:]), end="")
