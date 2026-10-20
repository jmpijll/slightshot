using System.Globalization;
using System.Net.Http.Headers;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace Slightshot.Core;

public readonly record struct ReleaseVersion(int Major, int Minor, int Patch) : IComparable<ReleaseVersion>
{
    // SemVer 2.0.0 with an optional leading "v". Build metadata is dropped;
    // a prerelease suffix is reported.
    private static readonly Regex Grammar = new(
        @"\Av?(?<major>0|[1-9][0-9]*)\.(?<minor>0|[1-9][0-9]*)\.(?<patch>0|[1-9][0-9]*)"
        + @"(?:-(?<pre>(?:0|[1-9][0-9]*|[0-9]*[A-Za-z-][0-9A-Za-z-]*)(?:\.(?:0|[1-9][0-9]*|[0-9]*[A-Za-z-][0-9A-Za-z-]*))*))?"
        + @"(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?\z",
        RegexOptions.CultureInvariant);

    public static bool TryParse(string? text, out ReleaseVersion version, out bool prerelease)
    {
        version = default; prerelease = false;
        var match = Grammar.Match(text ?? "");
        if (!match.Success
            || !int.TryParse(match.Groups["major"].ValueSpan, NumberStyles.None, CultureInfo.InvariantCulture, out int major)
            || !int.TryParse(match.Groups["minor"].ValueSpan, NumberStyles.None, CultureInfo.InvariantCulture, out int minor)
            || !int.TryParse(match.Groups["patch"].ValueSpan, NumberStyles.None, CultureInfo.InvariantCulture, out int patch))
            return false;
        version = new(major, minor, patch);
        prerelease = match.Groups["pre"].Success;
        return true;
    }

    public int CompareTo(ReleaseVersion other) =>
        Major != other.Major ? Major.CompareTo(other.Major) : Minor != other.Minor ? Minor.CompareTo(other.Minor) : Patch.CompareTo(other.Patch);
    public static bool operator >(ReleaseVersion left, ReleaseVersion right) => left.CompareTo(right) > 0;
    public static bool operator <(ReleaseVersion left, ReleaseVersion right) => left.CompareTo(right) < 0;
    public override string ToString() => $"{Major}.{Minor}.{Patch}";
}

public abstract record UpdateCheckResult
{
    private UpdateCheckResult() { }
    public sealed record UpToDate(string Version) : UpdateCheckResult;
    public sealed record Available(string Version, string CurrentVersion, Uri ReleasePage) : UpdateCheckResult;
    public sealed record Failed(string Reason) : UpdateCheckResult;
}

public static class ReleaseCheck
{
    public static readonly Uri LatestRelease = new("https://api.github.com/repos/jmpijll/slightshot/releases/latest");
    public static readonly TimeSpan Timeout = TimeSpan.FromSeconds(10);
    private const string ReleasePagePrefix = "/jmpijll/slightshot/releases/";
    private const string UnexpectedResponse = "GitHub returned an unexpected response. Try again later.";

    // The only data sent is an unauthenticated GET with a product User-Agent,
    // which GitHub's API requires.
    public static async Task<UpdateCheckResult> CheckAsync(HttpClient client, string currentVersion, TimeSpan timeout, CancellationToken cancellationToken = default)
    {
        if (!ReleaseVersion.TryParse(currentVersion, out var current, out _))
            return new UpdateCheckResult.Failed("The running Slightshot version could not be determined.");
        using var request = new HttpRequestMessage(HttpMethod.Get, LatestRelease);
        request.Headers.UserAgent.Add(new ProductInfoHeaderValue("Slightshot", current.ToString()));
        request.Headers.Accept.Add(new MediaTypeWithQualityHeaderValue("application/vnd.github+json"));
        using var deadline = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        deadline.CancelAfter(timeout);
        try
        {
            using var response = await client.SendAsync(request, deadline.Token).ConfigureAwait(false);
            if (!response.IsSuccessStatusCode)
                return new UpdateCheckResult.Failed($"GitHub returned HTTP {(int)response.StatusCode}. Try again later.");
            return Evaluate(current, await response.Content.ReadAsStringAsync(deadline.Token).ConfigureAwait(false));
        }
        catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
        {
            return new UpdateCheckResult.Failed($"GitHub did not respond within {timeout.TotalSeconds:0} seconds. Check your internet connection and try again.");
        }
        catch (HttpRequestException)
        {
            return new UpdateCheckResult.Failed("GitHub could not be reached. Check your internet connection and try again.");
        }
    }

    public static UpdateCheckResult Evaluate(ReleaseVersion current, string json)
    {
        try
        {
            using var document = JsonDocument.Parse(json);
            var root = document.RootElement;
            if (root.ValueKind != JsonValueKind.Object
                || !root.TryGetProperty("tag_name", out var tag) || tag.ValueKind != JsonValueKind.String
                || !ReleaseVersion.TryParse(tag.GetString(), out var latest, out bool prerelease)
                || !root.TryGetProperty("html_url", out var url) || url.ValueKind != JsonValueKind.String
                || !Uri.TryCreate(url.GetString(), UriKind.Absolute, out var page)
                || page.Scheme != Uri.UriSchemeHttps || page.Host != "github.com" || !page.IsDefaultPort
                || !page.AbsolutePath.StartsWith(ReleasePagePrefix, StringComparison.Ordinal))
                return new UpdateCheckResult.Failed(UnexpectedResponse);
            bool flaggedPrerelease = root.TryGetProperty("prerelease", out var flag) && flag.ValueKind == JsonValueKind.True;
            return latest > current && !prerelease && !flaggedPrerelease
                ? new UpdateCheckResult.Available(latest.ToString(), current.ToString(), page)
                : new UpdateCheckResult.UpToDate(current.ToString());
        }
        // GetString throws InvalidOperationException for unpaired UTF-16 surrogate escapes.
        catch (Exception exception) when (exception is JsonException or InvalidOperationException) { return new UpdateCheckResult.Failed(UnexpectedResponse); }
    }
}
