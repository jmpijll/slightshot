namespace Slightshot.Core;

public enum RecordingOwner { Running, Exited, Missing }

public enum RecordingDirectoryState { Live, Stale, Recoverable }

public static class RecordingDirectories
{
    public const string Prefix = "Slightshot-Recording-";
    public const string OwnerFile = ".owner";
    public const string KeepFile = ".keep";
    // A directory is created a moment before its owner lock; never sweep one mid-creation.
    public static readonly TimeSpan CreationGrace = TimeSpan.FromMinutes(1);

    public static RecordingDirectoryState Classify(RecordingOwner owner, bool keep, TimeSpan age) => owner switch
    {
        RecordingOwner.Running => RecordingDirectoryState.Live,
        RecordingOwner.Missing when age < CreationGrace => RecordingDirectoryState.Live,
        _ => keep ? RecordingDirectoryState.Recoverable : RecordingDirectoryState.Stale
    };
}
