using System.Text;
using Slightshot.Core;

internal enum FixtureFormat { Png, Jpeg }
internal sealed record FixtureKey(uint Key, uint Modifiers);
internal sealed class FixtureSettings
{
    public FixtureFormat Format { get; set; } = FixtureFormat.Png;
    public double Width { get; set; } = 3;
    public string Name { get; set; } = "default";
    public FixtureKey Shortcut { get; set; } = new(0x39, 6);
    public bool Sound { get; set; } = true;
}

internal static class SettingsFileChecks
{
    internal static int Run()
    {
        int checks = 0;
        void Require(bool condition, string message) { if (!condition) throw new InvalidOperationException("Settings file: " + message); checks++; }
        var now = new DateTime(2026, 10, 20, 9, 30, 15);
        string root = Path.Combine(Path.GetTempPath(), "slightshot-settings-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(root);
        try
        {
            string Fixture(string name, byte[] contents)
            {
                string directory = Path.Combine(root, name); Directory.CreateDirectory(directory);
                string path = Path.Combine(directory, "settings.json"); File.WriteAllBytes(path, contents); return path;
            }
            bool Defaults(FixtureSettings value) => value.Format == FixtureFormat.Png && value.Width == 3 && value.Name == "default" && value.Shortcut == new FixtureKey(0x39, 6) && value.Sound;

            string missing = Path.Combine(root, "missing", "settings.json");
            var absent = SettingsFile.Read<FixtureSettings>(missing, now);
            Require(Defaults(absent.Value) && absent.Recovery == null && !Directory.Exists(Path.GetDirectoryName(missing)), "a missing file loads defaults without a notice");

            string valid = Fixture("valid", Encoding.UTF8.GetBytes("""{"Format":1,"Width":7.5,"Name":"mine","Shortcut":{"Key":65,"Modifiers":3},"Sound":false,"Unknown":true}"""));
            var loaded = SettingsFile.Read<FixtureSettings>(valid, now);
            Require(loaded.Recovery == null && loaded.Value.Format == FixtureFormat.Jpeg && loaded.Value.Width == 7.5 && loaded.Value.Name == "mine" && loaded.Value.Shortcut == new FixtureKey(65, 3) && !loaded.Value.Sound, "a valid file loads every field");
            Require(Directory.GetFiles(Path.GetDirectoryName(valid)!).Length == 1, "a valid file is not backed up");

            string bom = Fixture("bom", [0xEF, 0xBB, 0xBF, .. Encoding.UTF8.GetBytes("""{"Name":"bom"}""")]);
            var bomRead = SettingsFile.Read<FixtureSettings>(bom, now);
            Require(bomRead.Recovery == null && bomRead.Value.Name == "bom", "a UTF-8 byte order mark is accepted");

            (string Name, byte[] Bytes)[] unreadable =
            [
                ("empty", []), ("whitespace", Encoding.UTF8.GetBytes(" \r\n ")), ("truncated", Encoding.UTF8.GetBytes("""{"Format":1,"Width":""")),
                ("array", Encoding.UTF8.GetBytes("[]")), ("null", Encoding.UTF8.GetBytes("null")), ("number", Encoding.UTF8.GetBytes("42")),
                ("string", Encoding.UTF8.GetBytes("\"settings\"")), ("trailing-comma", Encoding.UTF8.GetBytes("""{"Sound":false,}""")),
                ("binary", [0xFF, 0xFE, 0x00, 0x7B, 0x80]), ("deep", Encoding.UTF8.GetBytes("""{"Shortcut":""" + new string('[', 200) + new string(']', 200) + "}"))
            ];
            foreach (var (name, bytes) in unreadable)
            {
                string path = Fixture(name, bytes);
                var read = SettingsFile.Read<FixtureSettings>(path, now);
                Require(Defaults(read.Value), $"{name}: defaults load");
                Require(read.Recovery is { ResetFields.Count: 0, BackupPath: not null }, $"{name}: the whole file is reported as reset with a backup");
                Require(Path.GetFileName(read.Recovery!.BackupPath) == "settings.corrupt-20261020-093015.json", $"{name}: backup is named settings.corrupt-<timestamp>.json");
                Require(File.ReadAllBytes(read.Recovery.BackupPath!).SequenceEqual(bytes) && File.ReadAllBytes(path).SequenceEqual(bytes), $"{name}: backup keeps the original bytes and the file is not rewritten");
            }

            string fields = Fixture("fields", Encoding.UTF8.GetBytes("""{"Format":7,"Width":"wide","Name":null,"Shortcut":null,"Sound":false}"""));
            var partial = SettingsFile.Read<FixtureSettings>(fields, now);
            Require(partial.Value.Format == FixtureFormat.Png && partial.Value.Width == 3 && partial.Value.Name == "default" && partial.Value.Shortcut == new FixtureKey(0x39, 6), "undefined enum, wrong type and null fields fall back to defaults");
            Require(!partial.Value.Sound, "valid fields beside invalid ones are kept");
            Require(partial.Recovery is { BackupPath: not null } && string.Join(",", partial.Recovery.ResetFields) == "Format,Width,Name,Shortcut", "reset fields are reported in declaration order");

            string rejected = Fixture("rejected", Encoding.UTF8.GetBytes("""{"Shortcut":{"Key":65,"Modifiers":0},"Width":99}"""));
            var validated = SettingsFile.Read<FixtureSettings>(rejected, now, value => value is not FixtureKey { Modifiers: 0 });
            Require(validated.Value.Shortcut == new FixtureKey(0x39, 6) && validated.Value.Width == 99 && validated.Recovery?.ResetFields.SequenceEqual(["Shortcut"]) == true, "the caller's validator rejects a field");

            var again = SettingsFile.Read<FixtureSettings>(fields, now);
            Require(again.Recovery?.BackupPath is { } second && second != partial.Recovery!.BackupPath && File.Exists(partial.Recovery.BackupPath!), "a second backup in the same second does not replace the first");

            if (!OperatingSystem.IsWindows())
            {
                string locked = Fixture("locked", Encoding.UTF8.GetBytes("{"));
                File.SetUnixFileMode(Path.GetDirectoryName(locked)!, UnixFileMode.UserRead | UnixFileMode.UserExecute);
                var noBackup = SettingsFile.Read<FixtureSettings>(locked, now);
                File.SetUnixFileMode(Path.GetDirectoryName(locked)!, UnixFileMode.UserRead | UnixFileMode.UserWrite | UnixFileMode.UserExecute);
                Require(Defaults(noBackup.Value) && noBackup.Recovery is { BackupPath: null }, "a backup that cannot be written is reported so the file is not replaced");

                string hidden = Fixture("unreadable", Encoding.UTF8.GetBytes("""{"Name":"secret"}"""));
                File.SetUnixFileMode(hidden, UnixFileMode.None);
                var unopened = SettingsFile.Read<FixtureSettings>(hidden, now);
                File.SetUnixFileMode(hidden, UnixFileMode.UserRead | UnixFileMode.UserWrite);
                Require(Defaults(unopened.Value) && unopened.Recovery is { ResetFields.Count: 0, BackupPath: null }, "a file that cannot be opened is reported without a backup");
            }

            const string app = @"C:\Users\Ada\AppData\Local\Programs\Slightshot\Slightshot.exe";
            Require(LaunchAtLogin.Targets(LaunchAtLogin.Command(app), app), "the login command written for this copy targets it");
            Require(LaunchAtLogin.Targets(" " + app.ToUpperInvariant() + " ", app), "an unquoted, differently cased entry for this copy targets it");
            Require(!LaunchAtLogin.Targets(@"""C:\Users\Ada\Downloads\Slightshot.exe""", app), "an entry for a moved or other copy does not target this copy");
            Require(!LaunchAtLogin.Targets($"\"{app}\" --minimized", app) && !LaunchAtLogin.Targets(null, app) && !LaunchAtLogin.Targets("", app), "commands with arguments and missing entries do not target this copy");
        }
        finally { Directory.Delete(root, true); }
        return checks;
    }
}
