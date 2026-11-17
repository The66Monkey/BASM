frappe.listview_settings["ROT RUT Claim"] = {
  onload(listview) {
    listview.page.add_inner_button(__("Download Skatteverket XML"), () => {
      const selected = listview.get_checked_items().map((row) => row.name);
      if (!selected.length) {
        frappe.msgprint(__("Select submitted ROT/RUT claims first."));
        return;
      }
      frappe.call({
        method: "basm_rot_rut.api.download_xml",
        args: { names: selected },
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
  },
};
