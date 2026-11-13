# HotDog CMS

BASM installs HotDog CMS 0.11.0 as a verified CLI under
`<BASM_ROOT>/modules/hotdog/`. The starter site is in
`<BASM_ROOT>/modules/hotdog/site/`. HotDog automatically selects LAMP and
serves the published site at `hotdog.<primary-domain>` in production.

The HotDog site is separate from LAMP's existing
`<BASM_ROOT>/modules/lamp/www/`. Its publish target is
`<BASM_ROOT>/modules/lamp/hotdog/current/`, mounted read-only in the LAMP
container; publishing a new version does not replace the existing LAMP site.

## Edit, check, build, publish

Set the site name, URL, and other metadata in `site.yaml`. The production URL
is `https://hotdog.<primary-domain>`. Edit the site's Markdown and templates
inside that directory as root, then run:

```bash
cd /opt/basm/modules/hotdog/site
sudo ../hotdog-cms check
sudo ../hotdog-cms build
sudo ../hotdog-cms publish live
```

`check` builds and validates the site. `build` writes the static output to
`public/`. `publish live` checks and builds again, then atomically publishes
the result to the LAMP document root. The `live` target is recorded in
`site/publish.yaml`.

The starter includes a sample contact form addressed to `you@example.org`.
Replace or remove that placeholder before publishing; BASM's CLI-only setup
does not install the HotDog form endpoint.

For a local installation, open `http://hotdog.localhost:<HTTP_PORT>`; for LAN
mode, map `hotdog.basm.test` to the server's private address and use the BASM
HTTP port. The local URL is HTTP only.

Production DNS requires an A record for `hotdog.<primary-domain>`. BASM includes
that hostname in the installation handover and, for deSEC dynamic-IP installs,
in its automatic DNS updates.
