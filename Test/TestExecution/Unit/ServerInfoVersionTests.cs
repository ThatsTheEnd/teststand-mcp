using NUnit.Framework;
using TestStandMCP.Models;

namespace TestStandMCP.UnitTests;

/// <summary>
/// What a client sees in the MCP <c>initialize</c> response's <c>serverInfo</c> is built by
/// <see cref="VersionInfo.ToServerInfo"/> — the same source <c>--version</c> prints. The full
/// <c>initialize</c> round trip needs a running <c>McpServer</c>; the packaging smoke test covers it
/// over stdio.
/// </summary>
[TestFixture]
[Category("EngineFree")]
public class ServerInfoVersionTests
{
    [Test]
    public void ToServerInfo_CarriesProductNameAndTheResolvedVersion()
    {
        var info = VersionInfo.Resolve("1.9.0+abc123", versionTxtPath: null);

        var serverInfo = info.ToServerInfo();

        Assert.That(serverInfo.Name, Is.EqualTo(VersionInfo.ProductName));
        Assert.That(serverInfo.Version, Is.EqualTo("1.9.0"));
    }

    [Test]
    public void ToServerInfo_OfThisExecutable_ReportsTheCurrentVersionNotTheUntaggedOne()
    {
        var serverInfo = VersionInfo.Current.ToServerInfo();

        Assert.That(serverInfo.Name, Is.EqualTo(VersionInfo.ProductName));
        Assert.That(serverInfo.Version, Is.EqualTo(VersionInfo.Current.Version));
        Assert.That(serverInfo.Version, Is.Not.EqualTo("0.0.0-dev"), "an unstamped build must never present itself as a release");
        Assert.That(serverInfo.Version, Does.Match(@"^\d+\.\d+\.\d+"), "a version a client can compare");
    }
}
