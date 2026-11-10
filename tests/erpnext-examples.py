#!/usr/bin/env python3
"""Isolated seed tests; real ERPNext controller acceptance is documented separately."""

import copy
import importlib.util
import json
from pathlib import Path
import sys
import types
import unittest
from unittest.mock import patch


MODULES = {
    "Customer": "Selling", "Supplier": "Buying", "Item Group": "Setup", "Item": "Stock",
    "Warehouse": "Stock", "Quotation": "Selling", "Sales Order": "Selling",
    "Sales Invoice": "Accounts", "Purchase Invoice": "Accounts", "Supplier Quotation": "Buying",
    "Purchase Order": "Buying", "Material Request": "Stock", "Lead": "CRM", "Opportunity": "CRM",
    "Project": "Projects", "Task": "Projects", "Activity Type": "Projects", "Timesheet": "Projects",
    "BOM": "Manufacturing", "Location": "Assets", "Sales Person": "Setup",
    "Maintenance Visit": "Maintenance", "Quality Goal": "Quality Management",
    "Quality Procedure": "Quality Management", "Issue": "Support", "Note": "Desk",
}


class FakeDB:
    def __init__(self, owner):
        self.owner = owner
        self.marker = None
        self.commits = 0
        self.rollbacks = 0
        self.saved = ([], None)

    def get_default(self, key):
        assert key == seed.MARKER
        return self.marker

    def set_default(self, key, value):
        assert key == seed.MARKER
        self.marker = value

    def commit(self):
        self.commits += 1
        self.saved = (copy.deepcopy(self.owner.records), self.marker)

    def rollback(self):
        self.rollbacks += 1
        self.owner.records, self.marker = copy.deepcopy(self.saved)


class FakeFrappe(types.ModuleType):
    def __init__(self):
        super().__init__("frappe")
        self.db = FakeDB(self)
        self.ready = True
        self.company = types.SimpleNamespace(name="Test Company", default_currency="SEK")
        self.default_company = self.company.name
        self.companies = [self.company.name]
        self.modules = set(MODULES.values()) - {"Desk"} | {"Subcontracting", "Telephony", "Regional"}
        self.records = []
        self.fail_on = None
        self.submit_on = None
        self.destroyed = False
        self.defaults = types.SimpleNamespace(get_global_default=lambda key: self.default_company)

    def is_setup_complete(self):
        return self.ready

    @staticmethod
    def scrub(value):
        return value.lower().replace(" ", "_")

    def get_all(self, doctype, **kwargs):
        if doctype == "Module Def":
            assert kwargs["filters"] == {"app_name": "erpnext"}
            return self.modules
        assert doctype == "Company"
        return self.companies

    def get_doc(self, doctype, name):
        assert doctype == "Company" and name == self.company.name
        return self.company

    def new_doc(self, doctype):
        parent = self

        class Doc(types.SimpleNamespace):
            def update(self, values):
                for key, value in values.items():
                    setattr(self, key, value)

            def insert(self):
                if doctype == parent.fail_on:
                    raise ValueError("ERPNext controller rejected example")
                self.name = f'{doctype} {len(parent.records)} & / "'
                if doctype == parent.submit_on:
                    self.docstatus = 1
                parent.records.append(self)

        return Doc(doctype=doctype, meta=types.SimpleNamespace(module=MODULES[doctype]))

    def init(self, **kwargs):
        assert kwargs == {"site": "test.example", "sites_path": "sites"}

    def connect(self):
        pass

    def set_user(self, user):
        assert user == "Administrator"

    def destroy(self):
        self.destroyed = True


fake = FakeFrappe()
utils = types.ModuleType("frappe.utils")
utils.today = lambda: "2026-11-10"
utils.add_days = lambda date, days: {30: "2026-12-10", -1: "2026-11-09"}[days]
spec = importlib.util.spec_from_file_location(
    "basm_examples", Path(__file__).resolve().parents[1] / "templates/erpnext-examples.py"
)
seed = importlib.util.module_from_spec(spec)
with patch.dict(sys.modules, {"frappe": fake, "frappe.utils": utils}):
    spec.loader.exec_module(seed)


class ExamplesTest(unittest.TestCase):
    def setUp(self):
        self.frappe = FakeFrappe()
        self.patcher = patch.object(seed, "frappe", self.frappe)
        self.patcher.start()
        self.addCleanup(self.patcher.stop)

    def record(self, doctype):
        return next(record for record in self.frappe.records if record.doctype == doctype)

    def test_waits_for_setup_without_writes(self):
        self.frappe.ready = False
        self.assertFalse(seed.seed_examples())
        self.assertEqual(self.frappe.records, [])
        self.assertIsNone(self.frappe.db.marker)

    def test_pack_shape_and_safety(self):
        self.assertTrue(seed.seed_examples())
        records = self.frappe.records
        self.assertEqual({record.doctype for record in records}, set(MODULES))
        self.assertTrue(all(record.docstatus == 0 for record in records))
        manifest = json.loads(self.frappe.db.marker)
        self.assertEqual(len(manifest), len(records))
        self.assertTrue(all(set(entry) == {"doctype", "name", "module"} for entry in manifest))
        for doctype in ("Sales Invoice", "Purchase Invoice"):
            invoice = self.record(doctype)
            self.assertEqual(invoice.currency, "SEK")
            self.assertEqual(invoice.company, "Test Company")
            self.assertEqual(invoice.update_stock, 0)
            self.assertEqual(invoice.items[0]["qty"], 1)
            self.assertEqual(invoice.items[0]["rate"], 100)
            self.assertNotIn("schedule_date", invoice.items[0])
            self.assertIn("Do not submit", invoice.remarks)
        timesheet = self.record("Timesheet")
        task = self.record("Task")
        project = self.record("Project")
        log = timesheet.time_logs[0]
        self.assertEqual((log["project"], log["task"]), (project.name, task.name))
        self.assertEqual((log["hours"], log["is_billable"]), (1, 0))
        self.assertEqual(log["from_time"], "2026-11-09 09:00:00")
        self.assertEqual(log["to_time"], "2026-11-09 10:00:00")
        self.assertEqual(self.record("BOM").is_default, 0)
        self.assertEqual(self.record("Purchase Order").items[0]["schedule_date"], "2026-12-10")
        self.assertEqual(self.record("Sales Order").items[0]["delivery_date"], "2026-12-10")
        self.assertEqual(
            self.record("Material Request").items[0]["warehouse"], self.record("Warehouse").name
        )
        notes = [record for record in records if record.doctype == "Note"]
        self.assertEqual(len(notes), len(self.frappe.modules) + 1)
        self.assertTrue(all(note.public == 1 and note.notify_on_login == 0 for note in notes))
        self.assertEqual(
            {note.title for note in notes},
            {f"BASM Example: {module}" for module in self.frappe.modules} | {"BASM Example: Start Here"},
        )
        self.assertIn("%2F", notes[-1].content)
        self.assertIn("&amp;", notes[-1].content)
        self.assertNotIn(' & / "', notes[-1].content)
        self.assertEqual(self.frappe.company.default_currency, "SEK")

    def test_only_installed_modules_and_no_recreation(self):
        self.frappe.modules = {"Selling", "Buying", "Stock"}
        seed.seed_examples()
        self.assertFalse(any(record.doctype in {"Timesheet", "BOM", "Sales Invoice"} for record in self.frappe.records))
        before = copy.copy(self.frappe.records)
        self.assertFalse(seed.seed_examples())
        self.assertEqual(before, self.frappe.records)
        self.frappe.records.clear()
        self.assertFalse(seed.seed_examples())
        self.assertEqual(self.frappe.records, [])

    def test_ambiguous_company_fails_instead_of_guessing(self):
        self.frappe.default_company = None
        self.frappe.companies = ["A", "B"]
        with self.assertRaisesRegex(ValueError, "default ERPNext company"):
            seed.seed_examples()
        self.assertEqual(self.frappe.records, [])

    def test_single_company_fallback(self):
        self.frappe.default_company = None
        self.assertTrue(seed.seed_examples())

    def test_missing_currency_fails(self):
        self.frappe.company.default_currency = ""
        with self.assertRaisesRegex(ValueError, "default currency"):
            seed.seed_examples()
        self.assertEqual(self.frappe.records, [])

    def test_controller_failure_propagates_and_rolls_back_without_marker(self):
        self.frappe.fail_on = "Timesheet"
        with patch.object(sys, "argv", ["examples.py", "test.example"]):
            with self.assertRaisesRegex(ValueError, "controller rejected"):
                seed.main()
        self.assertIsNone(self.frappe.db.marker)
        self.assertEqual(self.frappe.db.commits, 0)
        self.assertEqual(self.frappe.db.rollbacks, 1)
        self.assertEqual(self.frappe.records, [])
        self.assertTrue(self.frappe.destroyed)

    def test_main_commits_only_a_new_pack(self):
        with patch.object(sys, "argv", ["examples.py", "test.example"]):
            seed.main()
            seed.main()
        self.assertEqual(self.frappe.db.commits, 1)
        self.assertEqual(self.frappe.db.rollbacks, 2)

    def test_unexpected_submission_is_rejected(self):
        self.frappe.submit_on = "Sales Invoice"
        with patch.object(sys, "argv", ["examples.py", "test.example"]):
            with self.assertRaisesRegex(ValueError, "unexpectedly submitted"):
                seed.main()
        self.assertEqual(self.frappe.db.commits, 0)
        self.assertEqual(self.frappe.records, [])
        self.assertIsNone(self.frappe.db.marker)


if __name__ == "__main__":
    unittest.main()
