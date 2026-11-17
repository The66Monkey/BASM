# ERPNext Swedish ROT/RUT

`basm_rot_rut` is an optional ERPNext v16 app included in the BASM Core source.
It records ROT/RUT invoice details, prints a Swedish invoice layout, and exports
submitted claims as Skatteverket v1.1 XML. It is not installed unless the
operator enables it.

## Enable the app

In the BASM setup wizard, answer **yes** to **Include Swedish ROT/RUT
workflow?** BASM pulls the official ERPNext v16 base image and builds the app
image on the host. The generated image is used by all ERPNext services, and
site initialization installs the app. No registry account, manual build, or
image publishing is required.

BASM rebuilds the image during updates when the app source or ERPNext base
changes. Its source and pinned base-image digest are included in backups so
recovery can rebuild the same image. The first build needs internet access and
additional Docker storage for the ERPNext build.

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
permissions, print rendering, and the image build still require acceptance
testing on a disposable ERPNext v16 site before production use.
