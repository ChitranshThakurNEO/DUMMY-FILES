using System;
using Microsoft.EntityFrameworkCore.Migrations;

#nullable disable

namespace WorkVista.Server.MigrationService.Migrations
{
    /// <inheritdoc />
    public partial class AddedMSIInventoryColumnsToNullable : Migration
    {
        /// <inheritdoc />
        protected override void Up(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.DropIndex(
                name: "IX_MSIInstallationInventory_NTID_EMPID_HostName_BuildNumber",
                table: "MSIInstallationInventory");

            migrationBuilder.AlterColumn<string>(
                name: "NTID",
                table: "MSIInstallationInventory",
                type: "nvarchar(100)",
                maxLength: 100,
                nullable: true,
                oldClrType: typeof(string),
                oldType: "nvarchar(100)",
                oldMaxLength: 100);

            migrationBuilder.AlterColumn<string>(
                name: "EMPID",
                table: "MSIInstallationInventory",
                type: "nvarchar(50)",
                maxLength: 50,
                nullable: true,
                oldClrType: typeof(string),
                oldType: "nvarchar(50)",
                oldMaxLength: 50);

            migrationBuilder.CreateTable(
                name: "JobHistories",
                columns: table => new
                {
                    Id = table.Column<long>(type: "bigint", nullable: false)
                        .Annotation("SqlServer:Identity", "1, 1"),
                    RunDate = table.Column<DateTime>(type: "datetime2", nullable: false),
                    JobName = table.Column<string>(type: "nvarchar(max)", nullable: false),
                    Status = table.Column<int>(type: "int", nullable: false),
                    StatusComment = table.Column<string>(type: "nvarchar(max)", nullable: true),
                    CreatedBy = table.Column<string>(type: "nvarchar(max)", nullable: true),
                    CreatedDate = table.Column<DateTime>(type: "datetime2", nullable: false)
                },
                constraints: table =>
                {
                    table.PrimaryKey("PK_JobHistories", x => x.Id);
                });
        }

        /// <inheritdoc />
        protected override void Down(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.DropTable(
                name: "JobHistories");

            migrationBuilder.AlterColumn<string>(
                name: "NTID",
                table: "MSIInstallationInventory",
                type: "nvarchar(100)",
                maxLength: 100,
                nullable: false,
                defaultValue: "",
                oldClrType: typeof(string),
                oldType: "nvarchar(100)",
                oldMaxLength: 100,
                oldNullable: true);

            migrationBuilder.AlterColumn<string>(
                name: "EMPID",
                table: "MSIInstallationInventory",
                type: "nvarchar(50)",
                maxLength: 50,
                nullable: false,
                defaultValue: "",
                oldClrType: typeof(string),
                oldType: "nvarchar(50)",
                oldMaxLength: 50,
                oldNullable: true);

            migrationBuilder.CreateIndex(
                name: "IX_MSIInstallationInventory_NTID_EMPID_HostName_BuildNumber",
                table: "MSIInstallationInventory",
                columns: new[] { "NTID", "EMPID", "HostName", "BuildNumber" },
                unique: true);
        }
    }
}
