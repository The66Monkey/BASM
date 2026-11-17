frappe.ui.form.on("ROT RUT Claim", {
  refresh(frm) {
    if (frm.doc.docstatus === 1) {
      frm.add_custom_button(__("Download Skatteverket XML"), () => {
        frappe.call({
          method: "basm_rot_rut.api.download_xml",
          args: { names: [frm.doc.name] },
          callback(response) {
            if (!response.message) return;
            const blob = new Blob([response.message.content], {
              type: "application/xml;charset=utf-8",
            });
            const url = URL.createObjectURL(blob);
            const link = document.createElement("a");
            link.href = url;
            link.download = response.message.filename;
            link.click();
            URL.revokeObjectURL(url);
          },
        });
      });
    }
  },
});
