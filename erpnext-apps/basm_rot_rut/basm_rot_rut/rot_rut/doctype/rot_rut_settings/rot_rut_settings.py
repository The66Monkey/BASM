import re

import frappe
from frappe.model.document import Document


class ROTRUTSettings(Document):
    def validate(self):
        value = (self.performer_org_number or "").strip()
        if not re.fullmatch(r"(?:\d{6}|\d{8})[-+]?\d{4}", value):
            frappe.throw("Enter the performer personal or organisation number in Skatteverket's accepted numeric format.")
