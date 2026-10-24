using NUnit.Framework;
using TestStandMCP.Models;

namespace TestStandMCP.UnitTests;

/// <summary>
/// The version a client sees in the MCP <c>initialize</c> response must be the one
/// <c>--version</c> prints — one source, <see cref="VersionInfo"/>. The full <c>initialize</c>
/// round trip needs a running <c>McpServer</c>; the packaging smoke test covers it over stdio.
/// </summary>
[TestFixture]
[Category("EngineFree")]
public class ServerInfoVersionTests
{
    [Test]
    public void McpServerInfo_Default_ReportsTheResolvedVersion()
    {
        var serverInfo = new McpServerInfo();

        // The test assembly carries its own distinctive version (see its csproj), so a hard-coded
        // literal in McpServerInfo cannot match it by coincidence.
        Assert.That(VersionInfo.Current.Version, Is.EqualTo("0.0.0-test"));
        Assert.That(serverInfo.Version, Is.EqualTo(VersionInfo.Current.Version));
    }
}
