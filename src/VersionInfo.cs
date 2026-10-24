using System;
using System.Collections.Generic;
using System.IO;
using System.Reflection;

namespace TestStandMCP;

/// <summary>
/// Which release this executable is — the single source for the <c>--version</c> output, the MCP
/// <c>serverInfo.version</c> and the startup log line, so the three can never disagree.
///
/// <para><b>Where each field comes from.</b> <see cref="Version"/> and <see cref="Commit"/> are stamped
/// into the assembly's informational version at build time (<c>X.Y.Z+sha</c>: the SDK appends
/// <c>SourceRevisionId</c> after a <c>'+'</c>). The release workflow's <c>VERSION.txt</c> only adds what
/// the assembly cannot know — the tag, the build time and the run URL.</para>
///
/// <para><b>An untagged build is <c>0.0.0-dev</c></b> (the csproj default), never a made-up number.
/// A missing or malformed <c>VERSION.txt</c> degrades to a <see cref="Note"/>; resolving a version
/// must never be able to stop the server from starting.</para>
/// </summary>
public sealed record VersionInfo(
    string Version,
    string? Commit,
    string? Tag,
    string? Built,
    string? Run,
    string? Note)
{
    /// <summary>The version of a build nobody stamped (the csproj default).</summary>
    public const string UntaggedVersion = "0.0.0-dev";

    private const char BuildMetadataSeparator = '+';
    private const char KeyValueSeparator = ':';
    private const string VersionTxtFileName = "VERSION.txt";
    private const string TagKey   = "tag";
    private const string BuiltKey = "built";
    private const string RunKey   = "run";

    // version and commit are listed so a VERSION.txt that carries them still counts as readable;
    // the assembly stays the authority for those two.
    private static readonly HashSet<string> RecognisedKeys =
        new(StringComparer.OrdinalIgnoreCase) { TagKey, "version", "commit", BuiltKey, RunKey };

    /// <summary>The version of THIS executable, resolved once. VERSION.txt sits one level above the exe.</summary>
    public static VersionInfo Current { get; } = Resolve(
        typeof(VersionInfo).Assembly.GetCustomAttribute<AssemblyInformationalVersionAttribute>()?.InformationalVersion,
        DefaultVersionTxtPath());

    /// <summary>
    /// Pure resolver. <paramref name="informationalVersion"/> is <c>X.Y.Z</c> or <c>X.Y.Z+sha</c>;
    /// <paramref name="versionTxtPath"/> is the optional release metadata file.
    /// </summary>
    public static VersionInfo Resolve(string? informationalVersion, string? versionTxtPath)
    {
        var (version, commit) = SplitInformationalVersion(informationalVersion);
        var metadata = ReadReleaseMetadata(versionTxtPath);

        // An untagged local build has no release metadata by design, so its absence is not worth a note.
        var note = version == UntaggedVersion ? null : metadata.Note;
        return new VersionInfo(version, commit, metadata.Tag, metadata.Built, metadata.Run, note);
    }

    private static string DefaultVersionTxtPath() =>
        Path.GetFullPath(Path.Combine(AppContext.BaseDirectory, "..", VersionTxtFileName));

    private static (string? Tag, string? Built, string? Run, string? Note) ReadReleaseMetadata(string? versionTxtPath)
    {
        if (string.IsNullOrWhiteSpace(versionTxtPath) || !File.Exists(versionTxtPath))
            return (null, null, null, $"release metadata absent ({versionTxtPath ?? VersionTxtFileName} not found)");

        string[] lines;
        try
        {
            lines = File.ReadAllLines(versionTxtPath);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            return (null, null, null, $"release metadata unreadable ({ex.Message})");
        }

        var values = ParseKeyValueLines(lines);
        if (values.Count == 0)
            return (null, null, null, $"release metadata unreadable ({versionTxtPath} has no key: value lines)");

        return (
            values.GetValueOrDefault(TagKey),
            values.GetValueOrDefault(BuiltKey),
            values.GetValueOrDefault(RunKey),
            null);
    }

    /// <summary>Recognised <c>key: value</c> lines only; the value keeps any further ':' (URLs, ISO times).</summary>
    private static Dictionary<string, string> ParseKeyValueLines(IEnumerable<string> lines)
    {
        var values = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        foreach (var line in lines)
        {
            var separatorIndex = line.IndexOf(KeyValueSeparator);
            if (separatorIndex <= 0)
                continue;

            var key = line[..separatorIndex].Trim();
            var value = line[(separatorIndex + 1)..].Trim();
            if (RecognisedKeys.Contains(key) && value.Length > 0)
                values[key] = value;
        }
        return values;
    }

    private static (string Version, string? Commit) SplitInformationalVersion(string? informationalVersion)
    {
        if (string.IsNullOrWhiteSpace(informationalVersion))
            return (UntaggedVersion, null);

        var separatorIndex = informationalVersion.IndexOf(BuildMetadataSeparator);
        if (separatorIndex < 0)
            return (informationalVersion.Trim(), null);

        var version = informationalVersion[..separatorIndex].Trim();
        var commit  = informationalVersion[(separatorIndex + 1)..].Trim();
        return (
            version.Length == 0 ? UntaggedVersion : version,
            commit.Length == 0 ? null : commit);
    }
}
