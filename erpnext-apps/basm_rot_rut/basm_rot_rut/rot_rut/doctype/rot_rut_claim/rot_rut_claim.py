from datetime import date
import re

import frappe
from frappe.model.document import Document
from frappe.utils import today

from basm_rot_rut.xml_export import WORK_TYPES, whole_kronor


PERSON_OR_ORG_NUMBER = re.compile(r"(?:\d{6}|\d{8})[-+]?\d{4}\Z")


class ROTRUTClaim(Document):
    def before_submit(self):
        self.validate_for_export()

    def validate_for_export(self):
        if not self.work_completed:
            frappe.throw("Confirm that the work is completed before submitting the claim.")
        if not self.electronic_payment_confirmed:
            frappe.throw("Confirm that electronic customer payment has been received.")

        invoice = frappe.get_doc("Sales Invoice", self.sales_invoice)
        if invoice.docstatus != 1:
            frappe.throw("The linked Sales Invoice must be submitted.")
        if invoice.company != self.company:
            frappe.throw("The claim company must match the linked Sales Invoice.")

        if not PERSON_OR_ORG_NUMBER.fullmatch((self.buyer_id or "").strip()):
            frappe.throw("Enter the buyer's personal or organisation number in the accepted numeric format.")
        invoice_number = (self.invoice_number or self.sales_invoice or "").strip()
        if len(invoice_number) > 20:
            frappe.throw("The invoice number for XML must be no more than 20 characters.")

        payment_date = date.fromisoformat(str(self.payment_date))
        if payment_date < date(2009, 7, 1) or payment_date > date.fromisoformat(today()):
            frappe.throw("Payment date must be between 1 July 2009 and today.")

        paid = whole_kronor(self.paid_amount, "Amount received")
        requested = whole_kronor(self.requested_amount, "Amount requested")
        labor = whole_kronor(self.labor_cost, "Labour cost")
        other_cost = whole_kronor(self.other_cost, "Other costs")
        if paid < 1 or requested < 1 or labor < 2:
            frappe.throw("Payment, requested amount and labour cost must be greater than zero.")
        if max(paid, requested, labor) > 99_999_999_999:
            frappe.throw("Claim amount exceeds Skatteverket's XML limit.")
        if other_cost > 9_999_999:
            frappe.throw("Other costs cannot exceed 9,999,999 SEK.")
        if paid + requested > labor:
            frappe.throw("Payment received plus amount requested must not exceed the labour cost.")

        if self.claim_type == "ROT":
            self.validate_rot_property()
        elif self.claim_type == "RUT":
            self.property_designation = None
            self.brf_org_number = None
            self.apartment_number = None
        else:
            frappe.throw("Select ROT or RUT.")

        work_types = WORK_TYPES[self.claim_type]
        if not self.work_areas or len(self.work_areas) > 100:
            frappe.throw("Add between 1 and 100 work areas.")
        has_hours_and_material = False
        has_subcontractor_hours = False
        for row in self.work_areas:
            if row.work_type not in work_types:
                frappe.throw(f"Work type {row.work_type} is not valid for {self.claim_type}.")
            if row.hours is not None and row.hours != "":
                hours = whole_kronor(row.hours, "Hours")
                if hours > 999:
                    frappe.throw("Hours for a work area cannot exceed 999.")
            else:
                hours = None
            if row.subcontractor_hours is not None and row.subcontractor_hours != "":
                subcontractor_hours = whole_kronor(row.subcontractor_hours, "Subcontractor hours")
                if subcontractor_hours > (hours or 0):
                    frappe.throw("Subcontractor hours cannot exceed the total hours for a work area.")
                if subcontractor_hours > 0:
                    has_subcontractor_hours = True
            if row.material_cost is not None and row.material_cost != "":
                material = whole_kronor(row.material_cost, "Material cost")
                if material > 9_999_999:
                    frappe.throw("Material cost for a work area cannot exceed 9,999,999 SEK.")
            else:
                material = None
            if hours is not None and material is not None:
                has_hours_and_material = True
        if not has_hours_and_material:
            frappe.throw("Enter hours and material cost for at least one work area.")
        if self.subcontractor_used and not has_subcontractor_hours:
            frappe.throw("Record subcontractor hours for at least one work area.")

    def validate_rot_property(self):
        if self.property_type == "Small house":
            if not (self.property_designation or "").strip():
                frappe.throw("Enter the property designation for a small house.")
            if len(self.property_designation) > 40:
                frappe.throw("Property designation cannot exceed 40 characters.")
            self.brf_org_number = None
            self.apartment_number = None
        elif self.property_type == "Housing association apartment":
            if not PERSON_OR_ORG_NUMBER.fullmatch((self.brf_org_number or "").strip()):
                frappe.throw("Enter a valid-format housing association organisation number.")
            if not (self.apartment_number or "").strip():
                frappe.throw("Enter the apartment number.")
            if len(self.apartment_number) > 25:
                frappe.throw("Apartment number cannot exceed 25 characters.")
            self.property_designation = None
        else:
            frappe.throw("Select the ROT property type.")
