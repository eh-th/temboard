import DataTable from "datatables.net-bs4";
import { createApp } from "vue";

import EnvironmentMigrationDialog from "./components/settings/EnvironmentMigrationDialog.vue";

createApp({
  components: {
    "environment-migration-dialog": EnvironmentMigrationDialog,
  },
  created() {
    this.$nextTick(() => {
      new DataTable("#tableGroups", { stateSave: true });

      $("#buttonLoadAddGroupForm").click(function () {
        $("#GroupModal").modal("show");
        $("[data-toggle=popover]").popover("hide");
        load_add_group_form("GroupModal", group_kind);
      });

      $(document).on("click", "[data-action=edit]", function () {
        $("#GroupModal").modal("show");
        $("[data-toggle=popover]").popover("hide");
        load_update_group_form("GroupModal", group_kind, $(this).data("group_name"));
      });

      $(document).on("click", "[data-action=delete]", function () {
        $("#GroupModal").modal("show");
        $("[data-toggle=popover]").popover("hide");
        load_delete_group_confirm("GroupModal", group_kind, $(this).data("group_name"));
      });
    });
  },
}).mount("#vue-app");
