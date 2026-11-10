#!/usr/bin/env python3
"""Run inside the ERPNext backend, with its site name as the only argument."""

import html
import json
import sys
from urllib.parse import quote

import frappe
from frappe.utils import add_days, today


PREFIX = "BASM Example"
MARKER = "basm_learning_examples_v1"
WARNING = (
    "Fictional learning example, not real business activity. Duplicate and adapt "
    "for your own work. Do not submit, send, pay or publish this example."
)
WALKTHROUGHS = {
    "Accounts": "Open the draft sales and purchase invoices. Review accounts, dates and totals; use Print Preview without submitting.",
    "CRM": "Open the example lead and opportunity, then compare them with the quotation.",
    "Selling": "Follow customer -> quotation -> sales order -> sales invoice. These are independent drafts, not submitted downstream documents.",
    "Buying": "Follow supplier -> supplier quotation -> purchase order -> purchase invoice. Compare prices without submitting or paying.",
    "Stock": "Open the example warehouse, stock item and material request. A request does not receive goods or change stock balances.",
    "Projects": "Open the project and task, then the one-hour, non-billable draft timesheet.",
    "Manufacturing": "Open the draft bill of materials to compare the finished item with its component. Work orders require a submitted BOM and are not generated.",
    "Assets": "Inspect the example location. Creating an asset requires your asset category and company-specific accounts; no depreciation or acquisition is posted.",
    "Maintenance": "Open the draft maintenance visit and its work-done log. No visit or schedule is submitted.",
    "Quality Management": "Open the example quality goal and procedure. Adapt their wording to your own quality process.",
    "Support": "Open the example support issue and review its status and description. No customer email is sent.",
    "Subcontracting": "Start with a service item and a subcontracted purchase order. Subcontracting orders require a submitted purchase order, so none is generated.",
    "Setup": "Review your company, currency, fiscal year and chart of accounts from first-run setup. Examples never replace those choices.",
    "Regional": "Review local tax and statutory settings with your accountant. Example invoices intentionally contain no tax advice or invented tax rates.",
    "ERPNext Integrations": "Configure an integration only with your own credentials and a sandbox endpoint. Examples never connect external services.",
    "Communication": "Review communication history on a document. Examples have no real recipient and send no messages.",
    "Telephony": "Configure a test provider before trying call workflows. Examples do not place calls or configure credentials.",
    "Portal": "Review portal permissions with a test customer account. Examples do not create portal logins or publish documents.",
    "Utilities": "Review import and other utilities with a backup first. Do not bulk-submit these fictional examples.",
    "Bulk Transaction": "Review bulk actions without executing them. Submitting examples would create real business effects.",
    "EDI": "Review trading-partner configuration with sandbox credentials. Examples do not exchange orders or messages.",
}


def seed_examples():
    if frappe.db.get_default(MARKER):
        return False
    if not frappe.is_setup_complete():
        print("ERPNext examples pending: complete the ERPNext first-run wizard.")
        return False

    company_name = frappe.defaults.get_global_default("company")
    if not company_name:
        companies = frappe.get_all("Company", filters={"is_group": 0}, pluck="name")
        if len(companies) != 1:
            raise ValueError("Select a default ERPNext company before creating learning examples.")
        company_name = companies[0]
    company = frappe.get_doc("Company", company_name)
    if not company.default_currency:
        raise ValueError("The ERPNext company needs a default currency for learning examples.")

    modules = set(frappe.get_all("Module Def", filters={"app_name": "erpnext"}, pluck="name"))
    records = []

    def create(doctype, **values):
        doc = frappe.new_doc(doctype)
        doc.update(values)
        doc.docstatus = 0
        doc.insert()
        if doc.docstatus != 0:
            raise ValueError(f"Learning example unexpectedly submitted: {doctype} {doc.name}")
        records.append({"doctype": doctype, "name": doc.name, "module": doc.meta.module})
        return doc.name

    def record_link(record):
        route = frappe.scrub(record["doctype"]).replace("_", "-")
        return (
            f'{html.escape(record["doctype"])}: <a href="/app/{route}/'
            f'{quote(record["name"], safe="")}">{html.escape(record["name"])}</a>'
        )

    date = today()
    due = add_days(date, 30)
    # These are dedicated example masters, never borrowed from existing customers/items.
    customer = create("Customer", customer_name=f"{PREFIX} Customer", customer_type="Company")
    supplier = create("Supplier", supplier_name=f"{PREFIX} Supplier", supplier_type="Company")
    group = create("Item Group", item_group_name=f"{PREFIX} Items", parent_item_group="All Item Groups")
    service = create(
        "Item", item_code=f"{PREFIX} Service", item_name=f"{PREFIX} Service",
        item_group=group, stock_uom="Nos", is_stock_item=0, description=WARNING,
    )
    component = create(
        "Item", item_code=f"{PREFIX} Component", item_name=f"{PREFIX} Component",
        item_group=group, stock_uom="Nos", is_stock_item=1, description=WARNING,
    )
    warehouse = create("Warehouse", warehouse_name=f"{PREFIX} Warehouse", company=company.name)

    def line(item=service, **values):
        return {"item_code": item, "qty": 1, "rate": 100, "description": WARNING, **values}

    common = {"company": company.name, "currency": company.default_currency, "conversion_rate": 1}
    if "Selling" in modules:
        create(
            "Quotation", **common, quotation_to="Customer", party_name=customer,
            transaction_date=date, valid_till=due, items=[line()], terms=WARNING,
        )
        create(
            "Sales Order", **common, customer=customer, transaction_date=date,
            delivery_date=due, items=[line(delivery_date=due)], terms=WARNING,
        )
    if "Accounts" in modules:
        create(
            "Sales Invoice", **common, customer=customer, posting_date=date,
            due_date=due, update_stock=0, items=[line()], remarks=WARNING,
        )
        create(
            "Purchase Invoice", **common, supplier=supplier, posting_date=date,
            due_date=due, update_stock=0, items=[line()], remarks=WARNING,
        )
    if "Buying" in modules:
        create(
            "Supplier Quotation", **common, supplier=supplier,
            transaction_date=date, items=[line()], terms=WARNING,
        )
        create(
            "Purchase Order", **common, supplier=supplier, transaction_date=date,
            schedule_date=due, items=[line(schedule_date=due)], terms=WARNING,
        )
    if "Stock" in modules:
        create(
            "Material Request", company=company.name, material_request_type="Purchase",
            transaction_date=date, schedule_date=due,
            items=[line(component, schedule_date=due, warehouse=warehouse)],
        )
    if "CRM" in modules:
        create("Lead", first_name=PREFIX, last_name="Lead", company_name=f"{PREFIX} Prospect")
        create(
            "Opportunity", **common, opportunity_from="Customer", party_name=customer,
            transaction_date=date, title=f"{PREFIX} Opportunity",
        )
    if "Projects" in modules:
        yesterday = add_days(date, -1)
        project = create(
            "Project", project_name=f"{PREFIX} Project", company=company.name,
            customer=customer, expected_start_date=yesterday, expected_end_date=due,
            notes=f"{WARNING}\nScope: plan and deliver a small example service.",
        )
        task = create(
            "Task", subject=f"{PREFIX} Task", project=project,
            exp_start_date=yesterday, exp_end_date=due,
            description=f"{WARNING}\nReview the scope and log one hour of planning.",
        )
        activity = create("Activity Type", activity_type=f"{PREFIX} Planning")
        create(
            "Timesheet", company=company.name, customer=customer, parent_project=project,
            time_logs=[{"activity_type": activity, "project": project, "task": task,
                        "from_time": f"{yesterday} 09:00:00", "to_time": f"{yesterday} 10:00:00",
                        "hours": 1, "is_billable": 0, "description": WARNING}],
        )
    if "Manufacturing" in modules:
        finished = create(
            "Item", item_code=f"{PREFIX} Finished Product", item_name=f"{PREFIX} Finished Product",
            item_group=group, stock_uom="Nos", is_stock_item=1, description=WARNING,
        )
        create(
            "BOM", **common, item=finished, quantity=1, is_default=0,
            items=[{"item_code": component, "qty": 1, "rate": 10}],
            description=WARNING,
        )
    if "Assets" in modules:
        create("Location", location_name=f"{PREFIX} Office")
    if "Maintenance" in modules:
        person = create("Sales Person", sales_person_name=f"{PREFIX} Technician", is_group=0)
        create(
            "Maintenance Visit", company=company.name, customer=customer, mntc_date=date,
            maintenance_type="Unscheduled", completion_status="Partially Completed",
            purposes=[{"item_code": service, "service_person": person,
                       "work_done": f"{WARNING}\nInspected sample equipment; follow-up inspection needed."}],
        )
    if "Quality Management" in modules:
        create("Quality Goal", goal=f"{PREFIX} Review all service deliveries")
        create(
            "Quality Procedure", quality_procedure_name=f"{PREFIX} Delivery Review",
            processes=[{"process_description": "Compare the delivery with the agreed scope."},
                       {"process_description": "Record findings and arrange any corrective work."}],
        )
    if "Support" in modules:
        create(
            "Issue", subject=f"{PREFIX} Support Request", customer=customer,
            description=f"{WARNING}\nReview a question about the sample service delivery and record a resolution.",
        )

    index = list(records)
    for module in sorted(modules):
        links = "".join(
            f"<li>{record_link(record)}</li>"
            for record in index if record["module"] == module
        )
        guidance = WALKTHROUGHS.get(
            module, "Review this module's workspace. Use fictional data only; never submit or publish learning examples."
        )
        create(
            "Note", title=f"{PREFIX}: {module}", public=1, notify_on_login=0,
            content=f"<p>{html.escape(WARNING)}</p><p>{html.escape(guidance)}</p>"
                    f"<ul>{links}</ul><p>Some workflows need submitted prerequisites or real configuration; "
                    "those are walkthroughs only. Find all example records in the BASM Example: Start Here note.</p>",
        )
    links = "".join(
        f"<li>{record_link(record)}</li>"
        for record in records
    )
    create(
        "Note", title=f"{PREFIX}: Start Here", public=1, notify_on_login=0,
        content=f"<p>{html.escape(WARNING)}</p><p>Reference records, projects and notes do not have a "
                "Draft/Submit lifecycle. They are saved fictional examples. Transactions remain Draft. "
                "No taxes, integrations or company settings are configured by this pack.</p>"
                f"<ul>{links}</ul><p>Delete dependent drafts before their linked master records. "
                "Deleted examples are not recreated by installer reruns or updates.</p>",
    )
    frappe.db.set_default(MARKER, json.dumps(records))
    print(f"Created {len(records)} BASM learning examples; no documents were submitted.")
    return True


def main():
    frappe.init(site=sys.argv[1], sites_path="sites")
    try:
        frappe.connect()
        frappe.set_user("Administrator")
        if seed_examples():
            frappe.db.commit()
    finally:
        if frappe.db:
            frappe.db.rollback()
        frappe.destroy()


if __name__ == "__main__":
    main()
