using Microsoft.EntityFrameworkCore.Migrations;

#nullable disable

namespace WorkVista.Server.MigrationService.Migrations
{
    /// <inheritdoc />
    public partial class AddedIndexesToMSIInventory : Migration
    {
        /// <inheritdoc />
        protected override void Up(MigrationBuilder migrationBuilder)
        {
            // The HostName + BuildNumber unique index is no longer created by the previous
            // migration. Drop it only if it exists (e.g. on databases that already applied it).
            migrationBuilder.Sql(@"
IF EXISTS (SELECT 1 FROM sys.indexes
           WHERE name = 'IX_MSIInstallationInventory_HostName_BuildNumber'
             AND object_id = OBJECT_ID(N'[dbo].[MSIInstallationInventory]'))
    DROP INDEX [IX_MSIInstallationInventory_HostName_BuildNumber]
        ON [dbo].[MSIInstallationInventory];");

            migrationBuilder.CreateIndex(
                name: "IX_MSIInstallationInventory_EMPID_NTID_HostName_BuildNumber",
                table: "MSIInstallationInventory",
                columns: new[] { "EMPID", "NTID", "HostName", "BuildNumber" },
                unique: true,
                filter: "[EMPID] IS NOT NULL AND [NTID] IS NOT NULL");
        }

        /// <inheritdoc />
        protected override void Down(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.DropIndex(
                name: "IX_MSIInstallationInventory_EMPID_NTID_HostName_BuildNumber",
                table: "MSIInstallationInventory");
        }
    }
}
