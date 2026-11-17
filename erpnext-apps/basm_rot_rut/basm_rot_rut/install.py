from pathlib import Path

import frappe
from frappe.custom.doctype.custom_field.custom_field import create_custom_fields


APP_PATH = Path(__file__).parent
INVOICE_FIELDS = [
    {
        "fieldname": "custom_rot_rut_section",
        "label": "Swedish ROT/RUT",
        "fieldtype": "Section Break",
        "insert_after": "customer",
    },
    {
        "fieldname": "custom_rot_rut_type",
        "label": "ROT/RUT type",
        "fieldtype": "Select",
        "options": "\nROT\nRUT",
        "insert_after": "custom_rot_rut_section",
    },
    {
        "fieldname": "custom_rot_rut_buyer_id",
        "label": "ROT/RUT buyer personal or organisation number",
        "fieldtype": "Data",
        "insert_after": "custom_rot_rut_type",
    },
    {
        "fieldname": "custom_rot_rut_property_type",
        "label": "ROT property type",
        "fieldtype": "Select",
        "options": "\nSmall house\nHousing association apartment",
        "insert_after": "custom_rot_rut_buyer_id",
    },
    {
        "fieldname": "custom_rot_rut_property_designation",
        "label": "Property designation",
        "fieldtype": "Data",
        "insert_after": "custom_rot_rut_property_type",
    },
    {
        "fieldname": "custom_rot_rut_brf_org_number",
        "label": "Housing association organisation number",
        "fieldtype": "Data",
        "insert_after": "custom_rot_rut_property_designation",
    },
    {
        "fieldname": "custom_rot_rut_apartment_number",
        "label": "Apartment number",
        "fieldtype": "Data",
        "insert_after": "custom_rot_rut_brf_org_number",
    },
    {
        "fieldname": "custom_rot_rut_work_type",
        "label": "ROT/RUT work type",
        "fieldtype": "Data",
        "insert_after": "custom_rot_rut_apartment_number",
    },
    {
        "fieldname": "custom_rot_rut_work_address",
        "label": "ROT/RUT work address",
        "fieldtype": "Data",
        "insert_after": "custom_rot_rut_work_type",
    },
    {
        "fieldname": "custom_rot_rut_work_start",
        "label": "ROT/RUT work period start",
        "fieldtype": "Date",
        "insert_after": "custom_rot_rut_work_address",
    },
    {
        "fieldname": "custom_rot_rut_work_end",
        "label": "ROT/RUT work period end",
        "fieldtype": "Date",
        "insert_after": "custom_rot_rut_work_start",
    },
    {
        "fieldname": "custom_rot_rut_f_tax_confirmed",
        "label": "Company approved for F-tax (verified)",
        "fieldtype": "Check",
        "default": "0",
        "insert_after": "custom_rot_rut_work_end",
    },
    {
        "fieldname": "custom_rot_rut_labor_cost",
        "label": "ROT/RUT labour cost (entered manually)",
        "fieldtype": "Currency",
        "insert_after": "custom_rot_rut_f_tax_confirmed",
    },
    {
        "fieldname": "custom_rot_rut_material_cost",
        "label": "ROT/RUT material cost (entered manually)",
        "fieldtype": "Currency",
        "insert_after": "custom_rot_rut_labor_cost",
    },
    {
        "fieldname": "custom_rot_rut_other_cost",
        "label": "ROT/RUT other costs (entered manually)",
        "fieldtype": "Currency",
        "insert_after": "custom_rot_rut_material_cost",
    },
    {
        "fieldname": "custom_rot_rut_reduction",
        "label": "ROT/RUT reduction offered (entered manually)",
        "fieldtype": "Currency",
        "insert_after": "custom_rot_rut_other_cost",
    },
    {
        "fieldname": "custom_rot_rut_customer_amount",
        "label": "Customer amount after reduction (entered manually)",
        "fieldtype": "Currency",
        "insert_after": "custom_rot_rut_reduction",
    },
]


def sync_invoice_fields():
    create_custom_fields({"Sales Invoice": INVOICE_FIELDS}, update=True)


def sync_print_format():
    name = "BASM ROT RUT Invoice"
    html = (
        APP_PATH / "print_format" / "basm_rot_rut_invoice" / "basm_rot_rut_invoice.html"
    ).read_text()
    values = {
        "doctype": "Print Format",
        "name": name,
        "doc_type": "Sales Invoice",
        "module": "ROT RUT",
        "custom_format": 1,
        "print_format_type": "Jinja",
        "standard": "No",
        "html": html,
    }
    if frappe.db.exists("Print Format", name):
        doc = frappe.get_doc("Print Format", name)
        doc.update(values)
        doc.save(ignore_permissions=True)
    else:
        frappe.get_doc(values).insert(ignore_permissions=True)


def after_install():
    sync_invoice_fields()
    sync_print_format()


def after_migrate():
    sync_invoice_fields()
    sync_print_format()
