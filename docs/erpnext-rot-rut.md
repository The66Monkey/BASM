# ERPNext Swedish ROT/RUT

`basm_rot_rut` is an optional ERPNext v16 app included in the BASM Core source.
It records ROT/RUT invoice details, prints a Swedish invoice layout, and exports
submitted claims as Skatteverket v1.1 XML. It is not installed unless the
operator enables it.

## Build and publish the ERPNext image

Run these commands from the BASM checkout. Choose a registry and image name
that the BASM Docker host can pull:

```sh
docker build \
  --build-arg BASE_IMAGE=frappe/erpnext:v16 \
  -t registry.example.com/company/basm-erpnext:v16-rot-rut \
  erpnext-apps/basm_rot_rut
docker push registry.example.com/company/basm-erpnext:v16-rot-rut
```

In the BASM setup wizard, answer **yes** to **Include Swedish ROT/RUT
workflow?** and enter the published image reference. BASM requires a custom
image reference tagged `v16` or `v16-*`; the stock ERPNext image is rejected
when the app is enabled. BASM uses this image for all ERPNext services and
installs the app on the site through its site initialization step.

The app's Dockerfile starts from the official ERPNext v16 image, installs the
app without additional dependencies, and builds its Desk assets. Rebuild and
publish the image when updating the app source. Keep BASM's normal image update
and recovery workflow in use.

## Create and print a claim

1. In **ROT RUT Settings**, enter the performing company's organisation number.
2. On a Sales Invoice, fill the ROT/RUT custom fields as applicable. The
   **F-skatt verified** checkbox is an operator attestation, not an automatic
   check. The print format includes work address and period when entered.
3. Use **BASM ROT RUT Invoice** from the Sales Invoice Print view.
4. Create a **ROT RUT Claim** linked to the submitted Sales Invoice. Enter the
   buyer identifier, claim type, payment date and amount, labour and other
   costs, property information for ROT, and one or more work areas.
5. Confirm that work is complete and the eligible electronic customer payment
   has been received, then submit the claim.

Invoice ROT/RUT amounts are manually entered and do not alter ERPNext invoice
totals, VAT, or ledger entries. The print layout displays the normal ERPNext
invoice total as well as any manually entered reduction and customer amount;
verify those values before issuing an invoice.

Submission checks the linked invoice, required confirmations, numeric
identifier format, supported work types, whole-krona amounts, basic XML bounds,
and that customer payment plus requested amount does not exceed labour cost.
It does not determine legal eligibility, calculate reduction amounts or annual
allowances, or replace review against current Skatteverket rules.

## Export requests

Select submitted claims in the **ROT RUT Claim** list and use the XML export
action. Each export contains 1–100 claims of one type (ROT or RUT); export the
other type separately. The app downloads a Skatteverket v1.1 XML file. Review
the data and upload it manually through Skatteverket's **Rot och rut –
företag** e-service. The app does not submit claims or report their decisions.

The v1.1 export format is intended for use from 1 January 2027. Verify the
current Skatteverket import requirements before uploading, especially for use
before that date.

## Tests and limitations

Run the XML generator tests from the app directory:

```sh
python -m unittest discover -s tests -v
```

The XML generator has focused ROT/RUT unit tests, and a generated example was
validated against the published v1.1 schema. App installation, DocType
permissions, print rendering, and the custom image still require acceptance
testing on a disposable ERPNext v16 site before production use.
