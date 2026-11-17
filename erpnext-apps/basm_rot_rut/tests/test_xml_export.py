import unittest
from datetime import date
from xml.etree import ElementTree as ET

from basm_rot_rut.xml_export import NAMESPACE, build_xml


class XMLExportTest(unittest.TestCase):
    def claim(self, **overrides):
        return {
            "claim_type": "ROT",
            "invoice_number": "SINV-2027-001",
            "buyer_id": "198001011234",
            "property_type": "Small house",
            "property_designation": "Example 1:2",
            "payment_date": "2027-02-01",
            "paid_amount": 700,
            "requested_amount": 300,
            "labor_cost": 1000,
            "other_cost": 100,
            "subcontractor_used": True,
            "staffing_company_used": False,
            "work_areas": [
                {"work_type": "BYGG", "hours": 10, "material_cost": 250},
            ],
            **overrides,
        }

    def test_builds_v11_rot_xml_with_escaped_values_and_flags(self):
        xml = build_xml(
            [self.claim(property_designation="A & B < 2")],
            "5560160680",
            today=date(2027, 2, 2),
        )
        root = ET.fromstring(xml)
        ns = {"p": NAMESPACE}
        self.assertEqual(root.findtext("p:TypAvBegaran", namespaces=ns), "ROT")
        self.assertEqual(root.findtext("p:Utforare", namespaces=ns), "5560160680")
        case = root.find("p:Arende", ns)
        self.assertEqual(
            case.findtext("p:Fastighet/p:Fastighetsbeteckning", namespaces=ns),
            "A & B < 2",
        )
        self.assertEqual(case.findtext("p:Underentreprenor", namespaces=ns), "true")
        self.assertEqual(case.findtext("p:Bemanningsforetag", namespaces=ns), "false")
        self.assertTrue(xml.startswith(b"<?xml version="))

    def test_builds_rut_without_rot_property(self):
        claim = self.claim(
            claim_type="RUT",
            property_type=None,
            property_designation=None,
            work_areas=[{"work_type": "STADNING", "hours": 3, "material_cost": 0}],
        )
        root = ET.fromstring(build_xml([claim], "5560160680", today=date(2027, 2, 2)))
        ns = {"p": NAMESPACE}
        case = root.find("p:Arende", ns)
        self.assertIsNone(case.find("p:Fastighet", ns))
        self.assertEqual(
            case.findtext("p:UtfortArbete/p:TypAvUtfortArbete", namespaces=ns),
            "STADNING",
        )

    def test_rejects_mixed_type_batches_and_excess_cases(self):
        with self.assertRaisesRegex(ValueError, "separately"):
            build_xml(
                [self.claim(), self.claim(claim_type="RUT")],
                "5560160680",
                today=date(2027, 2, 2),
            )
        with self.assertRaisesRegex(ValueError, "between 1 and 100"):
            build_xml([self.claim()] * 101, "5560160680", today=date(2027, 2, 2))

    def test_rejects_inconsistent_amounts_and_fractional_kronor(self):
        with self.assertRaisesRegex(ValueError, "must not exceed"):
            build_xml(
                [self.claim(paid_amount=800)],
                "5560160680",
                today=date(2027, 2, 2),
            )
        with self.assertRaisesRegex(ValueError, "whole number"):
            build_xml(
                [self.claim(requested_amount="300.50")],
                "5560160680",
                today=date(2027, 2, 2),
            )

    def test_requires_rot_property_and_payment_date_not_in_future(self):
        with self.assertRaisesRegex(ValueError, "property type"):
            build_xml(
                [self.claim(property_type=None)],
                "5560160680",
                today=date(2027, 2, 2),
            )
        with self.assertRaisesRegex(ValueError, "Payment date"):
            build_xml(
                [self.claim(payment_date="2027-02-03")],
                "5560160680",
                today=date(2027, 2, 2),
            )


if __name__ == "__main__":
    unittest.main()
