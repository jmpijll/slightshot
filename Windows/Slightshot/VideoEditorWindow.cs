using System.Diagnostics;
using System.Globalization;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Threading;
using Slightshot.Core;

namespace Slightshot;

internal sealed class VideoEditorWindow : Window
{
    private readonly VideoFrameSource source;
    private readonly Settings settings;
    private readonly Func<IReadOnlyList<TimedAnnotation>, Task<bool>> save;
    private readonly CancellationTokenSource lifetime = new();
    private readonly DispatcherTimer playback = new() { Interval = TimeSpan.FromMilliseconds(80) };
    private readonly Stopwatch clock = new();
    private readonly Dictionary<Tool, ToolbarButton> tools = [];
    private readonly VideoAnnotationSurface surface;
    private readonly Border viewport;
    private readonly Button play = new() { Content = "Play", Width = 65, Padding = new Thickness(10, 5, 10, 5) };
    private readonly Slider playhead;
    private readonly TextBlock elapsed = new() { MinWidth = 130, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(10, 0, 0, 0) };
    private readonly ListBox marks = new() { MinHeight = 90, MaxHeight = 190, Background = Brushes.Transparent, BorderThickness = new Thickness(0) };
    private readonly VideoRangeSlider range;
    private readonly TextBox begin, end;
    private readonly TextBlock beginLabel = new(), endLabel = new(), hint = new() { TextWrapping = TextWrapping.Wrap };
    private readonly StackPanel timing;
    private readonly Button delete, entire;
    private readonly ToolbarButton undo, redo, color;
    private readonly Button saveButton;
    private readonly Button select;
    private TextBox? textEntry;
    private PointD textOrigin;
    private bool updating, saving, closing, closeAfterSave, closeWhenSaveFinishes;
    private long seekVersion;
    private Task? previewTask;
    private TimeSpan playbackStart;
    private readonly TaskCompletionSource completion = new(TaskCreationOptions.RunContinuationsAsynchronously);
    internal VideoAnnotationHistory History { get; }
    internal TimeSpan Position { get; private set; }
    internal Task Completion => completion.Task;
    internal VideoAnnotationSurface Surface => surface;

    internal VideoEditorWindow(VideoFrameSource source, Settings settings, Func<IReadOnlyList<TimedAnnotation>, Task<bool>> save, bool? forceDark = null)
    {
        this.source = source; this.settings = settings; this.save = save;
        History = new(source.Duration);
        surface = new VideoAnnotationSurface(History, settings, source.Width, source.Height);
        Title = "Edit recording"; Width = Math.Min(1040, SystemParameters.WorkArea.Width - 40); Height = Math.Min(710, SystemParameters.WorkArea.Height - 65); MinWidth = 720; MinHeight = 560;
        WindowStartupLocation = WindowStartupLocation.CenterScreen;
        Appearance.ApplyWindowTheme(this, forceDark);
        var root = new Grid { Margin = new Thickness(16) };
        root.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        root.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        root.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        root.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(218) });

        var rail = new StackPanel { Margin = new Thickness(0, 0, 12, 0), VerticalAlignment = VerticalAlignment.Top };
        select = new Button { Content = "↖", ToolTip = "Select an annotation", Width = 30, Height = 30, Margin = new Thickness(0, 0, 0, 4) };
        AutomationProperties.SetName(select, "Select an annotation"); select.Click += (_, _) => SelectTool(null); rail.Children.Add(select);
        var icons = new StackPanel { Margin = new Thickness(4) };
        foreach (var tool in Enum.GetValues<Tool>())
        {
            var item = new ToolbarButton(IconForTool(tool), tool == Tool.Step ? "Numbered steps" : tool.ToString(), () => SelectTool(surface.ActiveTool == tool ? null : tool)) { Margin = new Thickness(0, 0, 0, 2), Accent = settings.AnnotationColor };
            tools.Add(tool, item); icons.Children.Add(item);
        }
        color = new ToolbarButton(null, "Colour", ShowPalette) { Swatch = settings.AnnotationColor, Margin = new Thickness(0, 4, 0, 2) };
        undo = new ToolbarButton(ProductIcon.Undo, "Undo  Ctrl+Z", Undo);
        redo = new ToolbarButton(ProductIcon.Redo, "Redo  Ctrl+Y / Ctrl+Shift+Z", Redo);
        icons.Children.Add(color); icons.Children.Add(undo); icons.Children.Add(redo); rail.Children.Add(new FrostedPanel(icons));
        root.Children.Add(rail);

        surface.AnnotationCreated = AddAnnotation; surface.SelectionRequested = SelectAnnotation;
        surface.TextRequested = BeginText; surface.PauseRequested = Pause;
        var videoBox = new Viewbox { Stretch = Stretch.Uniform, Child = surface };
        viewport = new Border { Background = Brushes.Black, CornerRadius = new CornerRadius(6), Child = videoBox, ClipToBounds = true };
        Grid.SetColumn(viewport, 1); root.Children.Add(viewport);
        viewport.SizeChanged += (_, _) => surface.ViewScale = Math.Max(0.05, Math.Min(viewport.ActualWidth / source.Width, viewport.ActualHeight / source.Height));

        var inspector = new StackPanel { Margin = new Thickness(16, 0, 0, 0) };
        inspector.Children.Add(new TextBlock { Text = "Annotations", FontWeight = FontWeights.SemiBold, Margin = new Thickness(0, 0, 0, 8) });
        AutomationProperties.SetName(marks, "Recording annotations");
        marks.SelectionChanged += (_, _) => { if (!updating && marks.SelectedItem is ListBoxItem { Tag: Guid id }) { CommitText(); History.Select(id); UpdateControls(); surface.Refresh(); } };
        inspector.Children.Add(marks);
        hint.Text = "Pause the video and draw with the screenshot tools. Every new annotation starts out visible for the whole clip.";
        hint.Foreground = (Brush)Resources["SecondaryBrush"]; hint.Margin = new Thickness(0, 12, 0, 12); inspector.Children.Add(hint);
        timing = new StackPanel { Margin = new Thickness(0, 8, 0, 0) };
        timing.Children.Add(new TextBlock { Text = "Visible during", FontWeight = FontWeights.SemiBold, Margin = new Thickness(0, 0, 0, 8) });
        var labels = new Grid();
        beginLabel.HorizontalAlignment = HorizontalAlignment.Left; endLabel.HorizontalAlignment = HorizontalAlignment.Right;
        labels.Children.Add(beginLabel); labels.Children.Add(endLabel); timing.Children.Add(labels);
        range = new VideoRangeSlider(source.Duration, History.MinimumDuration);
        range.EditBeginning += () => { Pause(); History.BeginTimingEdit(); };
        range.RangeChanged += (start, finish) => { History.PreviewTiming(TimeSpan.FromSeconds(start), TimeSpan.FromSeconds(finish)); UpdateControls(false); surface.Refresh(); };
        range.EditCompleted += () => { History.CommitTimingEdit(); UpdateControls(); };
        timing.Children.Add(range);
        var exact = new Grid(); exact.ColumnDefinitions.Add(new ColumnDefinition()); exact.ColumnDefinitions.Add(new ColumnDefinition());
        begin = TimeField("Annotation start time in seconds"); end = TimeField("Annotation end time in seconds");
        begin.Margin = new Thickness(0, 0, 6, 0); end.Margin = new Thickness(6, 0, 0, 0);
        exact.Children.Add(begin); Grid.SetColumn(end, 1); exact.Children.Add(end); timing.Children.Add(exact);
        timing.Children.Add(new TextBlock { Text = "Exact time in seconds", FontSize = 11, Foreground = (Brush)Resources["SecondaryBrush"], Margin = new Thickness(0, 5, 0, 0) });
        begin.LostKeyboardFocus += (_, _) => ChangeTiming(true); end.LostKeyboardFocus += (_, _) => ChangeTiming(false);
        begin.PreviewKeyDown += (_, e) => { if (e.Key == Key.Enter) { ChangeTiming(true); e.Handled = true; } };
        end.PreviewKeyDown += (_, e) => { if (e.Key == Key.Enter) { ChangeTiming(false); e.Handled = true; } };
        entire = new Button { Content = "Whole clip", Padding = new Thickness(9, 5, 9, 5), Margin = new Thickness(0, 10, 0, 6) };
        entire.Click += (_, _) => { Pause(); History.SetTiming(TimeSpan.Zero, source.Duration); UpdateControls(); surface.Refresh(); };
        delete = new Button { Content = "Delete annotation", Padding = new Thickness(9, 5, 9, 5) };
        delete.Click += (_, _) => DeleteSelected(); timing.Children.Add(entire); timing.Children.Add(delete); inspector.Children.Add(timing);
        var inspectorScroll = new ScrollViewer { Content = inspector, VerticalScrollBarVisibility = ScrollBarVisibility.Auto, HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled };
        Grid.SetColumn(inspectorScroll, 2); root.Children.Add(inspectorScroll);

        var footer = new Grid { Margin = new Thickness(0, 16, 0, 0) };
        footer.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        footer.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        footer.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        footer.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        play.Click += (_, _) => { CommitText(); if (clock.IsRunning) Pause(); else Play(); }; footer.Children.Add(play);
        playhead = RangeSlider("Recording playhead"); playhead.Margin = new Thickness(14, 0, 0, 0);
        playhead.ValueChanged += async (_, _) => { if (!updating) { Pause(); await SeekAsync(TimeSpan.FromSeconds(playhead.Value)); } };
        Grid.SetColumn(playhead, 1); footer.Children.Add(playhead);
        Grid.SetColumn(elapsed, 2); footer.Children.Add(elapsed);
        saveButton = new Button { Content = "Save MP4…", Padding = new Thickness(16, 6, 16, 6), Margin = new Thickness(14, 0, 0, 0) };
        saveButton.Click += async (_, _) => await SaveAsync();
        var outputActions = new StackPanel { Orientation = Orientation.Horizontal };
        var discard = new Button { Content = "Discard…", Padding = new Thickness(10, 6, 10, 6), Margin = new Thickness(12, 0, 0, 0) };
        discard.Click += (_, _) => Close(); outputActions.Children.Add(discard); outputActions.Children.Add(saveButton);
        Grid.SetColumn(outputActions, 3); footer.Children.Add(outputActions);
        Grid.SetRow(footer, 1); Grid.SetColumnSpan(footer, 3); root.Children.Add(footer); Content = root;
        playback.Tick += async (_, _) =>
        {
            if (closing || saving || !clock.IsRunning) return;
            var next = playbackStart + clock.Elapsed;
            if (next >= source.Duration) { Pause(); await SeekAsync(source.Duration); }
            else if (previewTask?.IsCompleted != false) await SeekAsync(next);
        };
        PreviewKeyDown += HandleKey;
        Closing += (_, e) =>
        {
            if (saving) { e.Cancel = true; return; }
            if (!closeAfterSave && !closing && MessageBox.Show(this, "Discard this recording?", "Edit recording", MessageBoxButton.YesNo, MessageBoxImage.Question) != MessageBoxResult.Yes) { e.Cancel = true; return; }
            closing = true; Pause(); lifetime.Cancel();
        };
        Closed += async (_, _) =>
        {
            try { if (previewTask != null) await previewTask; }
            catch (OperationCanceledException) { }
            finally { source.Dispose(); lifetime.Dispose(); completion.TrySetResult(); }
        };
        UpdateControls();
    }

    internal Task InitializeAsync() => SeekAsync(TimeSpan.Zero);
    internal async Task SeekAsync(TimeSpan position)
    {
        if (closing) return;
        Position = TimeSpan.FromTicks(Math.Clamp(position.Ticks, 0, source.Duration.Ticks)); seekVersion++;
        UpdatePlayhead();
        if (previewTask?.IsCompleted != false) previewTask = DecodeLatestAsync();
        await previewTask;
    }
    private async Task DecodeLatestAsync()
    {
        while (!closing)
        {
            long request = seekVersion; var target = Position;
            try
            {
                // Decode only the preview pixels that can be displayed. Marks
                // keep source coordinates, and export always uses source size.
                var image = await source.GetFrameAsync(target, lifetime.Token, 1280);
                if (closing) return;
                if (request != seekVersion) continue;
                surface.Position = target; surface.SetFrame(image); return;
            }
            catch (OperationCanceledException) when (lifetime.IsCancellationRequested) { return; }
            catch (Exception error)
            {
                Pause(); hint.Text = "Could not preview this frame. Your recording is still available. " + error.Message;
                return;
            }
        }
    }
    internal void AddAnnotation(Annotation annotation)
    {
        CommitText(); History.Add(annotation); UpdateControls(); surface.Refresh();
    }
    internal void SelectAnnotation(Guid? id) { CommitText(); History.Select(id); SelectTool(null); UpdateControls(); surface.Refresh(); }
    internal void SetSelectedTiming(TimeSpan start, TimeSpan finish) { History.SetTiming(start, finish); UpdateControls(); surface.Refresh(); }
    internal void Undo() { CommitText(); History.Undo(); UpdateControls(); surface.Refresh(); }
    internal void Redo() { CommitText(); History.Redo(); UpdateControls(); surface.Refresh(); }
    private void DeleteSelected() { CommitText(); History.DeleteSelected(); UpdateControls(); surface.Refresh(); }
    private void ChangeTiming(bool startChanged)
    {
        if (updating || History.Selected is not { } item) return;
        Pause(); double minimum = History.MinimumDuration.TotalSeconds;
        if (!double.TryParse((startChanged ? begin : end).Text, NumberStyles.Float, CultureInfo.CurrentCulture, out double seconds) || !double.IsFinite(seconds)) { UpdateControls(); return; }
        var start = TimeSpan.FromSeconds(startChanged ? Math.Clamp(seconds, 0, item.End.TotalSeconds - minimum) : item.Begin.TotalSeconds);
        var finish = TimeSpan.FromSeconds(startChanged ? item.End.TotalSeconds : Math.Clamp(seconds, item.Begin.TotalSeconds + minimum, source.Duration.TotalSeconds));
        History.SetTiming(start, finish); UpdateControls(); surface.Refresh();
    }
    private void SelectTool(Tool? tool)
    {
        CommitText(); Pause(); surface.CancelGesture(); surface.ActiveTool = tool;
        surface.Cursor = tool == null ? Cursors.Arrow : tool == Tool.Text ? Cursors.IBeam : Cursors.Cross;
        foreach (var pair in tools) { pair.Value.Selected = pair.Key == tool; pair.Value.InvalidateVisual(); }
        color.IsEnabled = tool is not (Tool.Blur or Tool.Pixelate); select.FontWeight = tool == null ? FontWeights.Bold : FontWeights.Normal;
    }
    private void ShowPalette()
    {
        var menu = new ContextMenu();
        foreach (string hex in OverlayStyle.Swatches)
        {
            var item = new MenuItem { Header = hex, Icon = new Border { Width = 14, Height = 14, Background = AnnotationRenderer.Brush(hex), CornerRadius = new CornerRadius(3) } };
            item.Click += (_, _) => { settings.AnnotationColor = hex; color.Swatch = hex; color.InvalidateVisual(); foreach (var button in tools.Values) { button.Accent = hex; button.InvalidateVisual(); } };
            menu.Items.Add(item);
        }
        menu.PlacementTarget = color; menu.IsOpen = true;
    }
    private void BeginText(PointD point)
    {
        CommitText(); textOrigin = point;
        var entry = new TextBox { MinWidth = 160, MinHeight = 60, MaxWidth = 400, AcceptsReturn = true, TextWrapping = TextWrapping.Wrap, Padding = new Thickness(8) };
        textEntry = entry;
        var column = new StackPanel { Margin = new Thickness(12) }; column.Children.Add(entry);
        var actions = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right, Margin = new Thickness(0, 10, 0, 0) };
        var cancel = new Button { Content = "Cancel", IsCancel = true, Padding = new Thickness(10, 4, 10, 4), Margin = new Thickness(0, 0, 8, 0) };
        var add = new Button { Content = "Add text", Padding = new Thickness(10, 4, 10, 4) };
        actions.Children.Add(cancel); actions.Children.Add(add); column.Children.Add(actions);
        var popup = new Window { Title = "Add text", Owner = this, Content = column, Width = 340, SizeToContent = SizeToContent.Height, WindowStartupLocation = WindowStartupLocation.CenterOwner, ResizeMode = ResizeMode.NoResize };
        Appearance.ApplyWindowTheme(popup); add.Click += (_, _) => popup.DialogResult = true;
        entry.PreviewKeyDown += (_, e) => { if (e.Key == Key.Escape) { popup.DialogResult = false; e.Handled = true; } else if (e.Key == Key.Enter && (Keyboard.Modifiers & ModifierKeys.Control) != 0) { popup.DialogResult = true; e.Handled = true; } };
        popup.Loaded += (_, _) => entry.Focus();
        if (popup.ShowDialog() != true) entry.Text = "";
        CommitText();
    }
    private void CommitText()
    {
        if (textEntry is not { } entry) return;
        textEntry = null;
        if (string.IsNullOrWhiteSpace(entry.Text)) return;
        double scale = Math.Max(0.05, surface.ViewScale);
        History.Add(new(Tool.Text, [textOrigin], settings.AnnotationColor, settings.LineWidth / scale, settings.FontSize / scale, entry.Text));
        UpdateControls(); surface.Refresh();
    }
    internal void Play()
    {
        if (saving || closing) return;
        if (Position >= source.Duration) { Position = TimeSpan.Zero; seekVersion++; }
        playbackStart = Position; clock.Restart(); playback.Start(); play.Content = "Pause";
    }
    internal void Pause() { clock.Stop(); playback.Stop(); play.Content = "Play"; }
    private async Task SaveAsync()
    {
        if (saving || closing) return;
        Pause(); CommitText(); surface.CancelGesture(); History.CommitTimingEdit(); saving = true; IsEnabled = false;
        bool completed = false;
        try { completed = await save(History.ExportSnapshot()); }
        catch (Exception error) { MessageBox.Show(this, "The recording could not be saved.\n\n" + error.Message, "Save recording", MessageBoxButton.OK, MessageBoxImage.Warning); }
        finally { saving = false; IsEnabled = true; }
        if (completed || closeWhenSaveFinishes) { closeAfterSave = true; Close(); } else { Activate(); Focus(); }
    }
    private void UpdateControls(bool rebuildList = true)
    {
        updating = true;
        try
        {
            if (rebuildList)
            {
                marks.Items.Clear();
                for (int index = 0; index < History.Items.Count; index++)
                {
                    var item = History.Items[index]; string label = item.Annotation.Tool == Tool.Text ? item.Annotation.Text.Replace('\n', ' ') : item.Annotation.Tool.ToString();
                    var row = new ListBoxItem { Content = $"{index + 1}. {label}", Tag = item.Id, ToolTip = $"{Time(item.Begin)} – {Time(item.End)}", Padding = new Thickness(5, 6, 5, 6), Foreground = Foreground };
                    marks.Items.Add(row); if (item.Id == History.SelectedId) marks.SelectedItem = row;
                }
            }
            var selected = History.Selected;
            timing.Visibility = selected != null ? Visibility.Visible : Visibility.Collapsed;
            if (selected != null)
            {
                range.SetRange(selected.Begin.TotalSeconds, selected.End.TotalSeconds);
                begin.Text = selected.Begin.TotalSeconds.ToString("0.00", CultureInfo.CurrentCulture); end.Text = selected.End.TotalSeconds.ToString("0.00", CultureInfo.CurrentCulture);
                beginLabel.Text = "From  " + Time(selected.Begin); endLabel.Text = "Until  " + Time(selected.End);
                hint.Text = "Drag the two handles to set when the selected annotation appears. Its position stays fixed.";
            }
            else hint.Text = "Pause the video and draw with the screenshot tools. Every new annotation starts out visible for the whole clip.";
            undo.IsEnabled = History.CanUndo; redo.IsEnabled = History.CanRedo;
            delete.IsEnabled = entire.IsEnabled = selected != null;
        }
        finally { updating = false; }
        UpdatePlayhead();
    }
    private void UpdatePlayhead()
    {
        bool previous = updating; updating = true;
        playhead.Value = Position.TotalSeconds; elapsed.Text = $"{Time(Position)} / {Time(source.Duration)}"; updating = previous;
    }
    private static TextBox TimeField(string label)
    {
        var field = new TextBox { Padding = new Thickness(6, 4, 6, 4), MinWidth = 60 };
        AutomationProperties.SetName(field, label); return field;
    }
    private Slider RangeSlider(string label)
    {
        var slider = new Slider { Minimum = 0, Maximum = source.Duration.TotalSeconds, SmallChange = 1.0 / 30, LargeChange = 1, TickFrequency = 1.0 / 30, IsSnapToTickEnabled = true, IsMoveToPointEnabled = true, Margin = new Thickness(0, 2, 0, 10) };
        AutomationProperties.SetName(slider, label); return slider;
    }
    private void HandleKey(object sender, KeyEventArgs e)
    {
        if (saving || textEntry != null || e.OriginalSource is TextBox) return;
        var modifiers = Keyboard.Modifiers;
        if ((modifiers & ModifierKeys.Control) != 0 && e.Key == Key.S) { _ = SaveAsync(); e.Handled = true; }
        else if ((modifiers & ModifierKeys.Control) != 0 && e.Key == Key.Z) { if ((modifiers & ModifierKeys.Shift) != 0) Redo(); else Undo(); e.Handled = true; }
        else if ((modifiers & ModifierKeys.Control) != 0 && e.Key == Key.Y) { Redo(); e.Handled = true; }
        else if (e.Key == Key.Delete || e.Key == Key.Back) { DeleteSelected(); e.Handled = true; }
        else if (e.Key == Key.Space && e.OriginalSource is not Slider and not Button) { if (clock.IsRunning) Pause(); else Play(); e.Handled = true; }
        else if (e.Key == Key.Escape) { Close(); e.Handled = true; }
    }
    internal void CloseFixture() { closeAfterSave = true; Close(); }
    internal void CloseForShutdown() { closeAfterSave = true; if (saving) closeWhenSaveFinishes = true; else Close(); }
    private static string Time(TimeSpan time) => $"{(int)time.TotalMinutes:00}:{time.Seconds:00}.{time.Milliseconds / 100}";
    private static ProductIcon IconForTool(Tool tool) => tool switch
    {
        Tool.Pen => ProductIcon.Pen, Tool.Line => ProductIcon.Line, Tool.Arrow => ProductIcon.Arrow,
        Tool.Rectangle => ProductIcon.Rectangle, Tool.Marker => ProductIcon.Marker, Tool.Text => ProductIcon.Text,
        Tool.Blur => ProductIcon.Blur, Tool.Pixelate => ProductIcon.Pixelate, Tool.Step => ProductIcon.Step,
        _ => throw new ArgumentOutOfRangeException(nameof(tool))
    };
}
