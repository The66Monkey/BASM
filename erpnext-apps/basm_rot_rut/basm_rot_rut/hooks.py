app_name = "basm_rot_rut"
app_title = "BASM ROT/RUT"
app_publisher = "BASM"
app_description = "Swedish ROT/RUT claim records and XML export"
app_email = "support@example.invalid"
app_license = "MIT"

after_install = "basm_rot_rut.install.after_install"
after_migrate = "basm_rot_rut.install.after_migrate"

doctype_js = {
    "ROT RUT Claim": "public/js/rot_rut_claim.js",
}
doctype_list_js = {
    "ROT RUT Claim": "public/js/rot_rut_claim_list.js",
}
