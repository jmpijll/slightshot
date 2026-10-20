using System.Globalization;
using System.Net.Http.Headers;
using System.Text.Json;

namespace Slightshot.Core;

public readonly record struct ReleaseVersion(int Major, int Minor, int Patch) : IComparable<ReleaseVersion>
{
    // Accepts "1.2.3" or "v1.2.3" with optional "-prerelease" and "+build"
    // suffixes. Build metadata is dropped; a prerelease suffix is reported.
    public static bool TryParse(string? text, out ReleaseVersion version, out bool prerelease)
    {
        version = default; prerelease = false;
        if (string.IsNullOrEmpty(text)) return false;
        string core = text.StartsWith('v') ? text[1..] : text;
        int build = core.IndexOf('+');
        if (build >= 0) core = core[..build];
        int suffix = core.IndexOf('-');
        if (suffix >= 0) { prerelease = suffix < core.Length - 1; if (!prerelease) return false; core = core[..suffix]; }
        string[] parts = core.Split('.');
        if (parts.Length != 3) return false;
        var numbers = new int[3];
        for (int i = 0; i < 3; i++)
            if (!int.TryParse(parts[i], NumberStyles.None, CultureInfo.InvariantCulture, out numbers[i])) return false;
        version = new(numbers[0], numbers[1], numbers[2]);
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
        catch (JsonException) { return new UpdateCheckResult.Failed(UnexpectedResponse); }
    }
}
