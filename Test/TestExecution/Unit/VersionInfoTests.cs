using System;
using System.IO;
using NUnit.Framework;

// Deliberately NOT TestStandMCP.IntegrationTests: that namespace owns the [SetUpFixture] that connects
// the TestStand engine once for the whole run, and these tests must run on a machine without one.
namespace TestStandMCP.UnitTests;

/// <summary>
/// <see cref="VersionInfo.Resolve"/> — engine-free. Version and commit come from the assembly's
/// informational version (<c>X.Y.Z+sha</c>); VERSION.txt only adds tag, build time and run URL.
/// </summary>
[TestFixture]
[Category("EngineFree")]
public class VersionInfoTests
{
    [Test]
    public void InformationalVersion_WithCommitSuffix_SplitsVersionAndCommit()
    {
        var info = VersionInfo.Resolve("1.9.0+abc123", versionTxtPath: null);

        Assert.That(info.Version, Is.EqualTo("1.9.0"));
        Assert.That(info.Commit, Is.EqualTo("abc123"));
    }

    [Test]
    public void InformationalVersion_WithoutCommitSuffix_HasNoCommit()
    {
        var info = VersionInfo.Resolve("1.9.0", versionTxtPath: null);

        Assert.That(info.Version, Is.EqualTo("1.9.0"));
        Assert.That(info.Commit, Is.Null);
    }

    [Test]
    public void InformationalVersion_PreRelease_KeepsThePreReleaseLabel()
    {
        var info = VersionInfo.Resolve("2.0.0-rc.1+abc123", versionTxtPath: null);

        Assert.That(info.Version, Is.EqualTo("2.0.0-rc.1"));
    }

    [TestCase(null)]
    [TestCase("")]
    [TestCase("   ")]
    public void InformationalVersion_Missing_ReportsTheUntaggedVersion(string? informationalVersion)
    {
        var info = VersionInfo.Resolve(informationalVersion, versionTxtPath: null);

        Assert.That(info.Version, Is.EqualTo("0.0.0-dev"));
        Assert.That(info.Commit, Is.Null);
    }

    [Test]
    public void InformationalVersion_WithEmptyCommitSuffix_HasNoCommit()
    {
        var info = VersionInfo.Resolve("1.9.0+", versionTxtPath: null);

        Assert.That(info.Version, Is.EqualTo("1.9.0"));
        Assert.That(info.Commit, Is.Null);
    }

    // ── VERSION.txt (tag / built / run) ───────────────────────────────────────

    private string _tempDir = "";

    [SetUp]
    public void CreateTempDir()
    {
        _tempDir = Path.Combine(Path.GetTempPath(), "VersionInfoTests_" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(_tempDir);
    }

    [TearDown]
    public void DeleteTempDir()
    {
        if (Directory.Exists(_tempDir))
            Directory.Delete(_tempDir, recursive: true);
    }

    private string WriteVersionTxt(string content)
    {
        var path = Path.Combine(_tempDir, "VERSION.txt");
        File.WriteAllText(path, content);
        return path;
    }

    [Test]
    public void VersionTxt_Present_AddsTagBuiltAndRun()
    {
        var path = WriteVersionTxt(
            "tag: v1.9.0\nversion: 1.9.0\ncommit: abc123\nbuilt: 2026-10-24T08:15:00Z\nrun: https://github.com/o/r/actions/runs/42\n");

        var info = VersionInfo.Resolve("1.9.0+abc123", path);

        Assert.That(info.Tag, Is.EqualTo("v1.9.0"));
        Assert.That(info.Built, Is.EqualTo("2026-10-24T08:15:00Z"), "the value must keep its own colons");
        Assert.That(info.Run, Is.EqualTo("https://github.com/o/r/actions/runs/42"));
        Assert.That(info.Note, Is.Null);
    }

    [Test]
    public void VersionTxt_DisagreeingVersionAndCommit_AssemblyWins()
    {
        var path = WriteVersionTxt("tag: v9.9.9\nversion: 9.9.9\ncommit: ffffff\n");

        var info = VersionInfo.Resolve("1.9.0+abc123", path);

        Assert.That(info.Version, Is.EqualTo("1.9.0"));
        Assert.That(info.Commit, Is.EqualTo("abc123"));
    }

    [Test]
    public void VersionTxt_KeysAreCaseInsensitiveAndPaddingIsTrimmed()
    {
        var path = WriteVersionTxt("  TAG :   v1.9.0  \r\n");

        var info = VersionInfo.Resolve("1.9.0", path);

        Assert.That(info.Tag, Is.EqualTo("v1.9.0"));
    }

    [Test]
    public void VersionTxt_Missing_ForATaggedBuild_NotesTheAbsenceAndKeepsVersionAndCommit()
    {
        var info = VersionInfo.Resolve("1.9.0+abc123", Path.Combine(_tempDir, "VERSION.txt"));

        Assert.That(info.Version, Is.EqualTo("1.9.0"));
        Assert.That(info.Commit, Is.EqualTo("abc123"));
        Assert.That(info.Tag, Is.Null);
        Assert.That(info.Note, Does.Contain("absent"));
    }

    [Test]
    public void VersionTxt_NullPath_ForATaggedBuild_NotesTheAbsence()
    {
        var info = VersionInfo.Resolve("1.9.0+abc123", versionTxtPath: null);

        Assert.That(info.Note, Does.Contain("absent"));
    }

    [TestCase("")]
    [TestCase("no key value lines here\n\njust prose")]
    [TestCase("unknown: value\n: no key\n")]
    public void VersionTxt_WithoutRecognisedKeyValueLines_ForATaggedBuild_NotesItIsUnreadable(string content)
    {
        var path = WriteVersionTxt(content);

        var info = VersionInfo.Resolve("1.9.0+abc123", path);

        Assert.That(info.Version, Is.EqualTo("1.9.0"));
        Assert.That(info.Commit, Is.EqualTo("abc123"));
        Assert.That(info.Tag, Is.Null);
        Assert.That(info.Note, Does.Contain("unreadable"));
    }

    [Test]
    public void VersionTxt_LockedByAnotherProcess_ForATaggedBuild_DoesNotThrow()
    {
        var path = WriteVersionTxt("tag: v1.9.0\n");
        using var exclusive = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.None);

        var info = VersionInfo.Resolve("1.9.0+abc123", path);

        Assert.That(info.Version, Is.EqualTo("1.9.0"));
        Assert.That(info.Note, Does.Contain("unreadable"));
    }

    [Test]
    public void UntaggedBuild_WithoutVersionTxt_HasNoNote()
    {
        var info = VersionInfo.Resolve(informationalVersion: null, Path.Combine(_tempDir, "VERSION.txt"));

        Assert.That(info.Version, Is.EqualTo("0.0.0-dev"));
        Assert.That(info.Note, Is.Null);
    }
}
