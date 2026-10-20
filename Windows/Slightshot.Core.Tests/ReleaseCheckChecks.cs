using System.Net;
using System.Text;
using Slightshot.Core;

internal static class ReleaseCheckChecks
{
    private const string Page = "https://github.com/jmpijll/slightshot/releases/tag/";

    internal static async Task<int> RunAsync()
    {
        int checks = 0;
        void Require(bool condition, string message) { if (!condition) throw new InvalidOperationException(message); checks++; }
        static ReleaseVersion Parse(string text) => ReleaseVersion.TryParse(text, out var version, out _) ? version : throw new InvalidOperationException(text);

        Require(Parse("1.10.0") > Parse("1.9.0"), "minor versions compare numerically");
        Require(Parse("2.0.0") > Parse("1.99.99") && Parse("1.6.1") > Parse("1.6.0"), "major and patch versions compare numerically");
        Require(Parse("v1.6.0") == Parse("1.6.0+abc123"), "leading v and build metadata are ignored");
        Require(ReleaseVersion.TryParse("1.7.0-beta.1", out var beta, out bool isBeta) && beta == new ReleaseVersion(1, 7, 0) && isBeta, "prerelease suffix is reported");
        Require(ReleaseVersion.TryParse("1.7.0-x-y.0+build.01", out _, out bool isPrerelease) && isPrerelease && ReleaseVersion.TryParse("0.0.0+20261020.sha-1", out _, out bool isStable) && !isStable, "valid prerelease and build identifiers are accepted");
        foreach (string malformed in new[] { "", "1.6", "1.6.0.1", "latest", "v", "1.x.0", "-1.6.0", " 1.6.0", "1.6.0-", "99999999999.0.0", "v1.7.0+", "v01.7.0", "1.07.0", "v1.7.0+bad value", "1.7.0-01", "1.7.0-rc..1", "1.7.0+a..b", "V1.7.0", "1.7.0\n", "１.7.0" })
            Require(!ReleaseVersion.TryParse(malformed, out _, out _), $"malformed version '{malformed}' is rejected");

        static string Release(string tag, string url, bool prerelease = false) =>
            $$"""{"tag_name":"{{tag}}","html_url":"{{url}}","prerelease":{{(prerelease ? "true" : "false")}},"body":"notes"}""";
        var current = Parse("1.9.0");
        Require(ReleaseCheck.Evaluate(current, Release("v1.10.0", Page + "v1.10.0")) is UpdateCheckResult.Available { Version: "1.10.0", CurrentVersion: "1.9.0" } available
            && available.ReleasePage == new Uri(Page + "v1.10.0"), "newer release is offered with its release page");
        Require(ReleaseCheck.Evaluate(current, Release("v1.9.0", Page + "v1.9.0")) is UpdateCheckResult.UpToDate { Version: "1.9.0" }, "same version is up to date");
        Require(ReleaseCheck.Evaluate(Parse("1.10.0"), Release("v1.9.0", Page + "v1.9.0")) is UpdateCheckResult.UpToDate { Version: "1.10.0" }, "older release is not offered");
        Require(ReleaseCheck.Evaluate(current, Release("v1.10.0-rc.1", Page + "v1.10.0-rc.1")) is UpdateCheckResult.UpToDate, "prerelease tag is ignored");
        Require(ReleaseCheck.Evaluate(current, Release("v1.10.0", Page + "v1.10.0", prerelease: true)) is UpdateCheckResult.UpToDate, "release flagged prerelease is ignored");
        foreach (string malformed in new[]
        {
            "", "not json", "[]", "null", """{"html_url":"https://github.com/jmpijll/slightshot/releases/tag/v2.0.0"}""",
            """{"tag_name":2,"html_url":"https://github.com/jmpijll/slightshot/releases/tag/v2.0.0"}""",
            Release("latest", Page + "latest"), Release("v2.0.0", "https://example.com/jmpijll/slightshot/releases/tag/v2.0.0"),
            Release("v2.0.0", "http://github.com/jmpijll/slightshot/releases/tag/v2.0.0"), Release("v2.0.0", "https://github.com/someone/else/releases/tag/v2.0.0"),
            Release("v2.0.0", "https://github.com:8443/jmpijll/slightshot/releases/tag/v2.0.0"), Release("v2.0.0", "file:///C:/Windows/System32/calc.exe"),
            """{"tag_name":"v2.0.0"}""",
            """{"tag_name":"v2.0.0\uD800","html_url":"https://github.com/jmpijll/slightshot/releases/tag/v2.0.0"}""",
            """{"tag_name":"v2.0.0","html_url":"https://github.com/jmpijll/slightshot/releases/tag/v2.0.0\uDC00"}""",
            Release("v1.10.0+", Page + "v1.10.0"), Release("v01.10.0", Page + "v01.10.0")
        })
            Require(ReleaseCheck.Evaluate(current, malformed) is UpdateCheckResult.Failed, $"malformed response is reported: {malformed}");

        var handler = new StubHandler();
        using var client = new HttpClient(handler);
        handler.Respond = _ => Task.FromResult(Json(HttpStatusCode.OK, Release("v1.10.0", Page + "v1.10.0")));
        Require(await ReleaseCheck.CheckAsync(client, "1.9.0", ReleaseCheck.Timeout) is UpdateCheckResult.Available { Version: "1.10.0" }, "network check offers newer release");
        var request = handler.Requests.Single();
        Require(request.Method == HttpMethod.Get && request.RequestUri == new Uri("https://api.github.com/repos/jmpijll/slightshot/releases/latest"), "one GET to the latest-release endpoint");
        Require(request.Headers.UserAgent.ToString() == "Slightshot/1.9.0", "request identifies Slightshot in its User-Agent");
        Require(request.Headers.Select(header => header.Key).Order().SequenceEqual(["Accept", "User-Agent"]), "request sends only Accept and User-Agent headers");
        Require(request.Headers.Authorization == null && request.Content == null, "request carries no authentication or body");

        handler.Respond = _ => Task.FromResult(Json(HttpStatusCode.OK, """{"tag_name":"v1.10.0\uD800","html_url":"https://github.com/jmpijll/slightshot/releases/tag/v1.10.0"}"""));
        Require(await ReleaseCheck.CheckAsync(client, "1.9.0", ReleaseCheck.Timeout) is UpdateCheckResult.Failed { Reason: var unpaired } && unpaired.StartsWith("GitHub returned an unexpected response.", StringComparison.Ordinal), "unpaired surrogate escape in a response is reported, not thrown");
        handler.Respond = _ => Task.FromResult(Json(HttpStatusCode.ServiceUnavailable, "{}"));
        Require(await ReleaseCheck.CheckAsync(client, "1.9.0", ReleaseCheck.Timeout) is UpdateCheckResult.Failed { Reason: "GitHub returned HTTP 503. Try again later." }, "HTTP error is reported");
        handler.Respond = _ => throw new HttpRequestException("offline");
        Require(await ReleaseCheck.CheckAsync(client, "1.9.0", ReleaseCheck.Timeout) is UpdateCheckResult.Failed { Reason: var offline } && offline.StartsWith("GitHub could not be reached.", StringComparison.Ordinal), "network failure is reported");
        handler.Respond = async token => { await Task.Delay(System.Threading.Timeout.Infinite, token); throw new InvalidOperationException("unreachable"); };
        Require(await ReleaseCheck.CheckAsync(client, "1.9.0", TimeSpan.FromMilliseconds(50)) is UpdateCheckResult.Failed { Reason: var slow } && slow.StartsWith("GitHub did not respond within", StringComparison.Ordinal), "timeout is reported");
        Require(await ReleaseCheck.CheckAsync(client, "Unknown", ReleaseCheck.Timeout) is UpdateCheckResult.Failed, "unknown running version is reported");
        Require(handler.Requests.Count == 5, "each check sends exactly one request and an unknown version sends none");
        using var cancelled = new CancellationTokenSource(); cancelled.Cancel();
        bool propagated = false;
        try { await ReleaseCheck.CheckAsync(client, "1.9.0", ReleaseCheck.Timeout, cancelled.Token); }
        catch (OperationCanceledException) { propagated = true; }
        Require(propagated, "caller cancellation is not reported as a timeout");
        return checks;
    }

    private static HttpResponseMessage Json(HttpStatusCode status, string body) =>
        new(status) { Content = new StringContent(body, Encoding.UTF8, "application/json") };

    private sealed class StubHandler : HttpMessageHandler
    {
        internal List<HttpRequestMessage> Requests { get; } = [];
        internal Func<CancellationToken, Task<HttpResponseMessage>> Respond { get; set; } = _ => throw new InvalidOperationException("no response configured");
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
        {
            Requests.Add(request);
            return Respond(cancellationToken);
        }
    }
}
