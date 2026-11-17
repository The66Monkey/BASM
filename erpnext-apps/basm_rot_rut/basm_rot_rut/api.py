import json
import re
from datetime import date as Date

import frappe
from frappe.utils import today

from basm_rot_rut.xml_export import build_xml


@frappe.whitelist()
def download_xml(names):
    if isinstance(names, str):
        try:
            names = json.loads(names)
        except json.JSONDecodeError:
            frappe.throw("Select submitted ROT/RUT claims to export.")
    if not isinstance(names, list) or not 1 <= len(names) <= 100:
        frappe.throw("Select between 1 and 100 submitted claims.")
    if any(not isinstance(name, str) or not name for name in names):
        frappe.throw("Every selected claim must have a valid name.")
    if len(names) != len(set(names)):
        frappe.throw("The selection contains duplicate claims.")

    claims = []
    for name in names:
        doc = frappe.get_doc("ROT RUT Claim", name)
        if doc.docstatus != 1:
            frappe.throw(f"Claim {name} must be submitted before XML export.")
        if not frappe.has_permission("ROT RUT Claim", "read", doc=doc):
            frappe.throw("You do not have permission to export every selected claim.")
        claims.append(
            {
                "claim_type": doc.claim_type,
                "invoice_number": doc.invoice_number or doc.sales_invoice,
                "sales_invoice": doc.sales_invoice,
                "buyer_id": doc.buyer_id,
                "property_type": doc.property_type,
                "property_designation": doc.property_designation,
                "brf_org_number": doc.brf_org_number,
                "apartment_number": doc.apartment_number,
                "payment_date": str(doc.payment_date),
                "paid_amount": doc.paid_amount,
                "requested_amount": doc.requested_amount,
                "labor_cost": doc.labor_cost,
                "other_cost": doc.other_cost,
                "subcontractor_used": doc.subcontractor_used,
                "staffing_company_used": doc.staffing_company_used,
                "work_areas": [
                    {
                        "work_type": row.work_type,
                        "hours": row.hours,
                        "material_cost": row.material_cost,
                    }
                    for row in doc.work_areas
                ],
            }
        )

    settings = frappe.get_single("ROT RUT Settings")
    if not frappe.has_permission("ROT RUT Settings", "read", doc=settings):
        frappe.throw("You do not have permission to read ROT/RUT settings.")
    try:
        content = build_xml(
            claims,
            settings.performer_org_number,
            today=Date.fromisoformat(today()),
        )
    except ValueError as error:
        frappe.throw(str(error))
    claim_type = claims[0]["claim_type"]
    filename = f"{claim_type}-{today()}-{re.sub(r'[^A-Za-z0-9_-]', '', names[0])}.xml"
    return {"filename": filename, "content": content.decode("utf-8")}
