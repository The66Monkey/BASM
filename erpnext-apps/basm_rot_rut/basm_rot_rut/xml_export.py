from datetime import date
from decimal import Decimal, InvalidOperation
import re
import xml.etree.ElementTree as ET


NAMESPACE = "http://xmls.skatteverket.se/se/skatteverket/skattered/begaran/1.1"
MAX_CASES = 100
MAX_AMOUNT = 99_999_999_999
PERSON_OR_ORG_NUMBER = re.compile(r"(?:\d{6}|\d{8})[-+]?\d{4}\Z")

WORK_TYPES = {
    "ROT": {
        "BYGG", "EL", "GLASARBETE", "MARKARBETE", "MALNING_TAPETSERING",
        "MURNING", "VVS",
    },
    "RUT": {
        "BARNPASSNING", "FLYTTJANSTER", "IT_TJANSTER", "KLAD_TEXTILVARD",
        "MOBLERING", "PERSONLIG_OMSORG", "REPARATION_VITVAROR", "SNOSKOTTNING",
        "STADNING", "TILLSYN_AV_BOSTAD", "TRADGARDSARBETE",
        "TRANSPORT_TILL_FORSALJNING", "TVATT_VID_TVATTINRATTNING",
    },
}


def whole_kronor(value, label):
    try:
        amount = Decimal(str(value))
    except (InvalidOperation, ValueError, TypeError):
        raise ValueError(f"{label} must be a whole number of SEK.") from None
    if not amount.is_finite() or amount != amount.to_integral_value():
        raise ValueError(f"{label} must be a whole number of SEK.")
    amount = int(amount)
    if amount < 0:
        raise ValueError(f"{label} cannot be negative.")
    return amount


def _text(parent, tag, value):
    child = ET.SubElement(parent, f"{{{NAMESPACE}}}{tag}")
    child.text = str(value)
    return child


def _person_or_org_number(value, label):
    value = (value or "").strip()
    if not PERSON_OR_ORG_NUMBER.fullmatch(value):
        raise ValueError(f"{label} must use a supported numeric identifier format.")
    return value


def _build_case(parent, case, today):
    invoice_number = (case.get("invoice_number") or case.get("sales_invoice") or "").strip()
    if len(invoice_number) > 20:
        raise ValueError("Invoice number cannot exceed 20 characters.")
    if invoice_number:
        _text(parent, "FakturaNr", invoice_number)

    _text(parent, "Kopare", _person_or_org_number(case.get("buyer_id"), "Buyer number"))

    claim_type = case["claim_type"]
    if claim_type == "ROT":
        property_node = ET.SubElement(parent, f"{{{NAMESPACE}}}Fastighet")
        property_type = case.get("property_type")
        if property_type == "Small house":
            designation = (case.get("property_designation") or "").strip()
            if not designation or len(designation) > 40:
                raise ValueError("ROT property designation must contain 1 to 40 characters.")
            _text(property_node, "Fastighetsbeteckning", designation)
        elif property_type == "Housing association apartment":
            _text(
                property_node,
                "BrfOrgNr",
                _person_or_org_number(case.get("brf_org_number"), "Housing association number"),
            )
            apartment = (case.get("apartment_number") or "").strip()
            if not apartment or len(apartment) > 25:
                raise ValueError("Apartment number must contain 1 to 25 characters.")
            _text(property_node, "LagenhetsNr", apartment)
        else:
            raise ValueError("Select a ROT property type.")

    work_areas = case.get("work_areas") or []
    if not work_areas or len(work_areas) > 100:
        raise ValueError("Each claim must contain between 1 and 100 work areas.")
    has_hours_and_material = False
    for work in work_areas:
        work_type = work.get("work_type")
        if work_type not in WORK_TYPES[claim_type]:
            raise ValueError(f"Work type {work_type!r} is not valid for {claim_type}.")
        work_node = ET.SubElement(parent, f"{{{NAMESPACE}}}UtfortArbete")
        _text(work_node, "TypAvUtfortArbete", work_type)
        hours_value = work.get("hours")
        material_value = work.get("material_cost")
        if hours_value not in (None, ""):
            hours = whole_kronor(hours_value, "Hours")
            if hours > 999:
                raise ValueError("Hours for a work area cannot exceed 999.")
            _text(work_node, "AntalTimmar", hours)
        if material_value not in (None, ""):
            material = whole_kronor(material_value, "Material cost")
            if material > 9_999_999:
                raise ValueError("Material cost for a work area cannot exceed 9,999,999 SEK.")
            _text(work_node, "Kostnad", material)
        if hours_value not in (None, "") and material_value not in (None, ""):
            has_hours_and_material = True
    if not has_hours_and_material:
        raise ValueError("Enter hours and material cost for at least one work area.")

    other_cost = whole_kronor(case.get("other_cost", 0), "Other costs")
    if other_cost > 9_999_999:
        raise ValueError("Other costs cannot exceed 9,999,999 SEK.")
    if other_cost:
        _text(parent, "OvrigKostnad", other_cost)

    try:
        payment_date = date.fromisoformat(str(case["payment_date"]))
    except (KeyError, ValueError):
        raise ValueError("Enter a valid payment date in YYYY-MM-DD format.") from None
    if payment_date < date(2009, 7, 1) or payment_date > today:
        raise ValueError("Payment date must be between 1 July 2009 and today.")
    _text(parent, "Betalningsdatum", payment_date.isoformat())

    labor = whole_kronor(case.get("labor_cost"), "Labour cost")
    paid = whole_kronor(case.get("paid_amount"), "Amount received")
    requested = whole_kronor(case.get("requested_amount"), "Amount requested")
    if labor < 2 or paid < 1 or requested < 1:
        raise ValueError("Labour cost, customer payment and requested amount must be greater than zero.")
    if max(labor, paid, requested) > MAX_AMOUNT:
        raise ValueError("Claim amount exceeds Skatteverket's XML limit.")
    if paid + requested > labor:
        raise ValueError("Customer payment plus requested amount must not exceed labour cost.")
    _text(parent, "Arbetskostnad", labor)
    _text(parent, "BetaltBelopp", paid)
    _text(parent, "BegartBelopp", requested)
    _text(parent, "Underentreprenor", "true" if case.get("subcontractor_used") else "false")
    _text(parent, "Bemanningsforetag", "true" if case.get("staffing_company_used") else "false")


def build_xml(claims, performer_org_number, *, today=None):
    if not 1 <= len(claims) <= MAX_CASES:
        raise ValueError(f"An export must contain between 1 and {MAX_CASES} claims.")
    today = today or date.today()
    claim_types = {claim.get("claim_type") for claim in claims}
    if len(claim_types) != 1 or next(iter(claim_types)) not in WORK_TYPES:
        raise ValueError("Export ROT and RUT requests separately.")
    claim_type = next(iter(claim_types))
    ET.register_namespace("p", NAMESPACE)
    root = ET.Element(f"{{{NAMESPACE}}}Begaran")
    _text(root, "NamnPaBegaran", f"BASM {claim_type}")
    _text(root, "TypAvBegaran", claim_type)
    _text(root, "Utforare", _person_or_org_number(performer_org_number, "Performer number"))
    for claim in claims:
        case = ET.SubElement(root, f"{{{NAMESPACE}}}Arende")
        _build_case(case, claim, today)
    return ET.tostring(root, encoding="utf-8", xml_declaration=True)
