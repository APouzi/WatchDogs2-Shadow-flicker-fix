using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.IO;
using System.Reflection;
using System.Security.AccessControl;
using System.Security.Principal;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using System.Web.Script.Serialization;
using System.Windows.Forms;

[assembly: AssemblyTitle("Alexandre's Watch Dogs 2 Shadow Flicker")]
[assembly: AssemblyDescription("Windows setup wizard for the Watch Dogs 2 NVIDIA shadow flicker workaround")]
[assembly: AssemblyCompany("Alexandre Pouzikov")]
[assembly: AssemblyProduct("Alexandre's Watch Dogs 2 Shadow Flicker")]
[assembly: AssemblyVersion("1.1.0.0")]
[assembly: AssemblyFileVersion("1.1.0.0")]
[assembly: AssemblyCopyright("Alexandre Pouzikov")]

namespace WatchDogs2FlickerFix
{
    public static class InstallerResult
    {
        public static string Classify(int exitCode, bool hasError, string state)
        {
            if (!hasError && exitCode == 0 && state == "Succeeded") return "Succeeded";
            if (!hasError && (exitCode == 2 || state == "Cancelled")) return "Cancelled";
            return "Failed";
        }
    }

    internal sealed class SetupProgressBar : Control
    {
        private int value;
        internal SetupProgressBar()
        {
            SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer, true);
            AccessibleRole = AccessibleRole.ProgressBar;
            TabStop = false;
        }
        public int Value
        {
            get { return value; }
            set
            {
                this.value = Math.Max(0, Math.Min(100, value));
                Invalidate();
                AccessibilityNotifyClients(AccessibleEvents.ValueChange, -1);
            }
        }
        protected override void OnPaint(PaintEventArgs e)
        {
            Color track = SystemInformation.HighContrast ? SystemColors.Control : Color.FromArgb(229, 236, 245);
            Color fill = SystemInformation.HighContrast ? SystemColors.Highlight : Color.FromArgb(30, 107, 186);
            using (Brush brush = new SolidBrush(track)) e.Graphics.FillRectangle(brush, ClientRectangle);
            using (Brush brush = new SolidBrush(fill)) e.Graphics.FillRectangle(brush, 0, 0, (int)Math.Round(Width * value / 100.0), Height);
        }
        protected override AccessibleObject CreateAccessibilityInstance() { return new ProgressAccessibility(this); }
        private sealed class ProgressAccessibility : ControlAccessibleObject
        {
            private readonly SetupProgressBar owner;
            internal ProgressAccessibility(SetupProgressBar owner) : base(owner) { this.owner = owner; }
            public override AccessibleRole Role { get { return AccessibleRole.ProgressBar; } }
            public override string Value { get { return owner.Value.ToString() + "%"; } set { } }
        }
    }

    internal static class Program
    {
        [STAThread]
        private static int Main()
        {
            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);
            if (!Environment.Is64BitOperatingSystem || Environment.OSVersion.Version.Major < 10)
            {
                MessageBox.Show("This installer requires 64-bit Windows 10 or Windows 11.", "Windows requirement", MessageBoxButtons.OK, MessageBoxIcon.Information);
                return 1;
            }
            WindowsPrincipal user = new WindowsPrincipal(WindowsIdentity.GetCurrent());
            if (!user.IsInRole(WindowsBuiltInRole.Administrator))
            {
                MessageBox.Show("Administrator access is needed to save the NVIDIA game-profile settings. Start the installer again and approve the Windows prompt.", "Administrator access needed", MessageBoxButtons.OK, MessageBoxIcon.Information);
                return 1;
            }
            bool created;
            using (Mutex instance = new Mutex(true, "Local\\AlexandresWatchDogs2ShadowFlickerSetup", out created))
            {
                if (!created)
                {
                    MessageBox.Show("The installer is already open.", "Installer already running", MessageBoxButtons.OK, MessageBoxIcon.Information);
                    return 1;
                }
                try { Application.Run(new SetupForm()); }
                catch (Exception error)
                {
                    MessageBox.Show(error.Message, "Unable to open the installer", MessageBoxButtons.OK, MessageBoxIcon.Error);
                    return 1;
                }
                finally { instance.ReleaseMutex(); }
            }
            return 0;
        }
    }

    internal sealed class SetupForm : Form
    {
        private const string TitleText = "Alexandre's Watch Dogs 2 Shadow Flicker";
        private readonly Color ink = Color.FromArgb(25, 43, 66);
        private readonly Color muted = Color.FromArgb(82, 99, 119);
        private readonly Color blue = Color.FromArgb(30, 107, 186);
        private readonly Panel welcome = new Panel();
        private readonly Panel work = new Panel();
        private readonly RadioButton apply = new RadioButton();
        private readonly RadioButton restore = new RadioButton();
        private readonly RadioButton status = new RadioButton();
        private readonly TextBox gameFolder = new TextBox();
        private readonly Button next = new Button();
        private readonly Button cancel = new Button();
        private readonly Label heading = new Label();
        private readonly Label message = new Label();
        private readonly Label percent = new Label();
        private readonly Label footnote = new Label();
        private readonly SetupProgressBar progress = new SetupProgressBar();
        private readonly TextBox details = new TextBox();
        private readonly System.Windows.Forms.Timer poll = new System.Windows.Forms.Timer();
        private readonly StringBuilder log = new StringBuilder();
        private string runDirectory;
        private string progressPath;
        private string cancellationPath;
        private string selectedAction = "Apply";
        private string lastState = "Running";
        private string lastMessage = "Preparing...";
        private int lastPercent;
        private bool running;
        private bool finished;
        private volatile bool cancellationRequested;

        internal SetupForm()
        {
            Text = TitleText;
            Font = new Font("Segoe UI", 10F);
            ForeColor = ink;
            BackColor = Color.White;
            StartPosition = FormStartPosition.CenterScreen;
            ClientSize = new Size(940, 700);
            MinimumSize = new Size(680, 480);
            AutoScaleMode = AutoScaleMode.Font;
            try { Icon = Icon.ExtractAssociatedIcon(Assembly.GetExecutingAssembly().Location); } catch { }

            TableLayoutPanel layout = new TableLayoutPanel();
            layout.Dock = DockStyle.Fill;
            layout.ColumnCount = 1;
            layout.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100F));
            layout.RowCount = 3;
            layout.RowStyles.Add(new RowStyle(SizeType.Absolute, 180));
            layout.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
            layout.RowStyles.Add(new RowStyle(SizeType.Absolute, 90));
            Controls.Add(layout);

            Panel header = new Panel();
            header.Size = new Size(940, 180);
            header.Dock = DockStyle.Fill;
            PictureBox logo = new PictureBox();
            logo.Location = new Point(28, 5);
            logo.Size = new Size(670, 166);
            logo.Anchor = AnchorStyles.Left | AnchorStyles.Top | AnchorStyles.Right | AnchorStyles.Bottom;
            logo.SizeMode = PictureBoxSizeMode.Zoom;
            logo.AccessibleName = TitleText + " cloud logo";
            using (Stream stream = Assembly.GetExecutingAssembly().GetManifestResourceStream("WatchDogs2FlickerFix.logo.png"))
            using (Image image = Image.FromStream(stream)) { logo.Image = new Bitmap(image); }
            header.Controls.Add(logo);
            Label version = new Label();
            version.Text = "SETUP 1.1.0\r\nWindows 10 / 11\r\nNVIDIA graphics";
            version.TextAlign = ContentAlignment.MiddleRight;
            version.ForeColor = muted;
            version.Font = new Font("Segoe UI", 9F);
            version.Location = new Point(722, 50);
            version.Size = new Size(184, 70);
            version.Anchor = AnchorStyles.Top | AnchorStyles.Right;
            header.Controls.Add(version);
            Panel rule = new Panel();
            rule.BackColor = Color.FromArgb(227, 233, 240);
            rule.Height = 1;
            rule.Dock = DockStyle.Bottom;
            header.Controls.Add(rule);
            layout.Controls.Add(header, 0, 0);

            Panel content = new Panel();
            content.Size = new Size(934, 424);
            content.Dock = DockStyle.Fill;
            content.Padding = new Padding(34, 16, 34, 6);
            content.AutoScroll = true;
            content.AutoScrollMinSize = new Size(0, 432);
            content.Controls.Add(welcome);
            content.Controls.Add(work);
            welcome.Dock = DockStyle.Top;
            work.Dock = DockStyle.Top;
            welcome.Size = new Size(866, 410);
            work.Size = new Size(866, 410);
            welcome.MinimumSize = new Size(860, 410);
            work.MinimumSize = new Size(860, 410);
            BuildWelcome();
            BuildWork();
            work.Visible = false;
            layout.Controls.Add(content, 0, 1);

            Panel footer = new Panel();
            footer.Size = new Size(940, 90);
            footer.Dock = DockStyle.Fill;
            footer.BackColor = Color.FromArgb(246, 248, 251);
            footnote.Text = "Original flag values are backed up before applying the fix.";
            footnote.ForeColor = muted;
            footnote.Location = new Point(34, 23);
            footnote.Size = new Size(515, 48);
            footnote.Font = new Font("Segoe UI", 9F);
            footnote.Anchor = AnchorStyles.Left | AnchorStyles.Right | AnchorStyles.Top;
            footer.Controls.Add(footnote);
            StyleButton(cancel, "Cancel", false);
            cancel.Location = new Point(654, 22);
            cancel.Anchor = AnchorStyles.Right | AnchorStyles.Top;
            cancel.Click += delegate { RequestCancel(); };
            footer.Controls.Add(cancel);
            StyleButton(next, "Continue", true);
            next.Location = new Point(790, 22);
            next.Anchor = AnchorStyles.Right | AnchorStyles.Top;
            next.Click += delegate { if (finished) Close(); else BeginOperation(); };
            footer.Controls.Add(next);
            layout.Controls.Add(footer, 0, 2);
            AcceptButton = next;
            CancelButton = cancel;
            FormClosing += OnClosing;
            Shown += delegate { FitToWorkingArea(); };
            poll.Interval = 150;
            poll.Tick += delegate { ReadProgress(); };
        }

        private void FitToWorkingArea()
        {
            Rectangle area = Screen.FromControl(this).WorkingArea;
            int width = Math.Min(Width, Math.Max(320, area.Width - 24));
            int height = Math.Min(Height, Math.Max(320, area.Height - 24));
            MinimumSize = new Size(Math.Min(MinimumSize.Width, width), Math.Min(MinimumSize.Height, height));
            Size = new Size(width, height);
            Location = new Point(area.Left + (area.Width - Width) / 2, area.Top + (area.Height - Height) / 2);
        }

        private void StyleButton(Button button, string text, bool primary)
        {
            button.Text = text;
            button.Size = new Size(120, 44);
            button.FlatStyle = FlatStyle.Flat;
            button.FlatAppearance.BorderSize = primary ? 0 : 1;
            button.FlatAppearance.BorderColor = Color.FromArgb(190, 202, 216);
            button.BackColor = primary ? blue : Color.White;
            button.ForeColor = primary ? Color.White : ink;
            button.Cursor = Cursors.Hand;
            button.AccessibleName = text;
        }

        private Label MakeLabel(string text, float size, FontStyle style, int x, int y, int width, int height)
        {
            Label label = new Label();
            label.Text = text;
            label.Font = new Font("Segoe UI", size, style);
            label.Location = new Point(x, y);
            label.Size = new Size(width, height);
            label.Anchor = AnchorStyles.Top | AnchorStyles.Left | AnchorStyles.Right;
            return label;
        }

        private void BuildWelcome()
        {
            welcome.Controls.Add(MakeLabel("Fix flickering shadows", 22F, FontStyle.Bold, 0, 0, 860, 44));
            Label intro = MakeLabel("Choose an action, then select Continue. Close Watch Dogs 2 before applying or undoing the fix.", 10F, FontStyle.Regular, 1, 51, 850, 42);
            intro.ForeColor = muted;
            welcome.Controls.Add(intro);
            ConfigureChoice(apply, "Apply the shadow fix", "Back up the original values, update the game profile, and verify the change.", 98);
            ConfigureChoice(restore, "Undo the fix", "Restore the two original flag values from a previous backup.", 166);
            ConfigureChoice(status, "Check current status", "Find the game and read its NVIDIA profile without changing the settings.", 234);
            apply.Checked = true;

            Label folderLabel = MakeLabel("Game folder (optional)", 9F, FontStyle.Bold, 1, 307, 830, 24);
            welcome.Controls.Add(folderLabel);
            gameFolder.Location = new Point(2, 335);
            gameFolder.Size = new Size(704, 28);
            gameFolder.Anchor = AnchorStyles.Left | AnchorStyles.Right | AnchorStyles.Top;
            gameFolder.AccessibleName = "Optional Watch Dogs 2 game folder";
            gameFolder.TabIndex = 3;
            welcome.Controls.Add(gameFolder);
            Button browse = new Button();
            StyleButton(browse, "Browse...", false);
            browse.Size = new Size(126, 31);
            browse.Location = new Point(715, 333);
            browse.Anchor = AnchorStyles.Right | AnchorStyles.Top;
            browse.TabIndex = 4;
            browse.Click += delegate
            {
                using (FolderBrowserDialog picker = new FolderBrowserDialog())
                {
                    picker.Description = "Choose the Watch Dogs 2 install folder or its bin folder.";
                    picker.ShowNewFolderButton = false;
                    if (Directory.Exists(gameFolder.Text)) picker.SelectedPath = gameFolder.Text;
                    if (picker.ShowDialog(this) == DialogResult.OK) gameFolder.Text = picker.SelectedPath;
                }
            };
            welcome.Controls.Add(browse);
            Label folderHint = MakeLabel("Leave blank to find Steam, Epic Games, or Ubisoft installs automatically.", 9F, FontStyle.Regular, 2, 373, 840, 30);
            folderHint.ForeColor = muted;
            welcome.Controls.Add(folderHint);
        }

        private void ConfigureChoice(RadioButton choice, string title, string description, int y)
        {
            choice.Text = title;
            choice.Font = new Font("Segoe UI", 11F, FontStyle.Bold);
            choice.Location = new Point(2, y);
            choice.Size = new Size(830, 30);
            choice.Anchor = AnchorStyles.Top | AnchorStyles.Left | AnchorStyles.Right;
            choice.AccessibleDescription = description;
            choice.TabIndex = y == 98 ? 0 : y == 166 ? 1 : 2;
            welcome.Controls.Add(choice);
            Label body = MakeLabel(description, 9F, FontStyle.Regular, 25, y + 32, 814, 28);
            body.ForeColor = muted;
            welcome.Controls.Add(body);
        }

        private void BuildWork()
        {
            heading.Font = new Font("Segoe UI", 22F, FontStyle.Bold);
            heading.Location = new Point(0, 1);
            heading.Size = new Size(850, 44);
            heading.Anchor = AnchorStyles.Left | AnchorStyles.Top | AnchorStyles.Right;
            work.Controls.Add(heading);
            message.ForeColor = muted;
            message.Location = new Point(2, 56);
            message.Size = new Size(838, 51);
            message.Anchor = AnchorStyles.Left | AnchorStyles.Top | AnchorStyles.Right;
            message.AccessibleName = "Current setup step";
            work.Controls.Add(message);
            progress.Location = new Point(3, 118);
            progress.Size = new Size(785, 25);
            progress.Anchor = AnchorStyles.Left | AnchorStyles.Top | AnchorStyles.Right;
            progress.AccessibleName = "Setup progress";
            work.Controls.Add(progress);
            percent.Location = new Point(792, 119);
            percent.Size = new Size(50, 28);
            percent.TextAlign = ContentAlignment.TopRight;
            percent.Anchor = AnchorStyles.Top | AnchorStyles.Right;
            work.Controls.Add(percent);
            Label detailLabel = MakeLabel("Operation details", 9F, FontStyle.Bold, 2, 164, 830, 25);
            work.Controls.Add(detailLabel);
            details.Multiline = true;
            details.ReadOnly = true;
            details.ScrollBars = ScrollBars.Vertical;
            details.BackColor = Color.FromArgb(247, 249, 252);
            details.ForeColor = ink;
            details.Font = new Font("Consolas", 9F);
            details.BorderStyle = BorderStyle.FixedSingle;
            details.Location = new Point(3, 195);
            details.Size = new Size(838, 205);
            details.Anchor = AnchorStyles.Left | AnchorStyles.Right | AnchorStyles.Top | AnchorStyles.Bottom;
            details.AccessibleName = "Setup operation log";
            work.Controls.Add(details);
        }

        private void BeginOperation()
        {
            if (running) return;
            selectedAction = restore.Checked ? "Restore" : status.Checked ? "Status" : "Apply";
            string folder = gameFolder.Text.Trim().Trim('"');
            if (folder.Length > 0 && !Directory.Exists(folder) && !File.Exists(folder))
            {
                MessageBox.Show(this, "Choose an existing game folder, or leave the field blank for automatic detection.", "Game folder not found", MessageBoxButtons.OK, MessageBoxIcon.Information);
                gameFolder.Focus();
                return;
            }
            welcome.Visible = false;
            work.Visible = true;
            running = true;
            next.Enabled = false;
            AcceptButton = null;
            heading.Text = selectedAction == "Restore" ? "Undoing the fix" : selectedAction == "Status" ? "Checking the game profile" : "Applying the shadow fix";
            message.Text = "Preparing the installer...";
            percent.Text = "0%";
            footnote.Text = "Cancel stops at a safe checkpoint before profile changes begin.";
            log.Clear();
            AppendLog("Starting " + selectedAction + ".");
            Task.Factory.StartNew(delegate { RunBackend(folder); });
        }

        private static string QuotePowerShell(string value) { return "'" + value.Replace("'", "''") + "'"; }

        private void RunBackend(string gamePath)
        {
            int exitCode = 1;
            Exception failed = null;
            try
            {
                runDirectory = CreateSecureRunDirectory();
                string scriptPath = Path.Combine(runDirectory, "WatchDogs2-FlickerFix.ps1");
                progressPath = Path.Combine(runDirectory, "progress.json");
                cancellationPath = Path.Combine(runDirectory, "cancellation.json");
                using (Stream source = Assembly.GetExecutingAssembly().GetManifestResourceStream("WatchDogs2FlickerFix.backend.ps1"))
                using (FileStream target = new FileStream(scriptPath, FileMode.CreateNew, FileAccess.Write, FileShare.None)) { source.CopyTo(target); }
                if (cancellationRequested) File.WriteAllText(cancellationPath, "cancel", Encoding.UTF8);
                string command = "[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false); & " + QuotePowerShell(scriptPath) + " -Action " + QuotePowerShell(selectedAction) + " -ProgressFile " + QuotePowerShell(progressPath) + " -CancellationFile " + QuotePowerShell(cancellationPath);
                if (gamePath.Length > 0) command += " -GamePath " + QuotePowerShell(gamePath);
                string encoded = Convert.ToBase64String(Encoding.Unicode.GetBytes(command));
                ProcessStartInfo start = new ProcessStartInfo();
                start.FileName = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows), "System32\\WindowsPowerShell\\v1.0\\powershell.exe");
                start.Arguments = "-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand " + encoded;
                start.WorkingDirectory = Environment.GetFolderPath(Environment.SpecialFolder.System);
                start.UseShellExecute = false;
                start.CreateNoWindow = true;
                start.RedirectStandardOutput = true;
                start.RedirectStandardError = true;
                start.StandardOutputEncoding = Encoding.UTF8;
                start.StandardErrorEncoding = Encoding.UTF8;
                using (Process backend = new Process())
                {
                    backend.StartInfo = start;
                    backend.OutputDataReceived += delegate(object sender, DataReceivedEventArgs line) { if (line.Data != null) Dispatch(delegate { AppendLog(line.Data); }); };
                    backend.ErrorDataReceived += delegate(object sender, DataReceivedEventArgs line) { if (line.Data != null) Dispatch(delegate { AppendLog(line.Data); }); };
                    if (!backend.Start()) throw new InvalidOperationException("The Windows PowerShell helper could not be started.");
                    backend.BeginOutputReadLine();
                    backend.BeginErrorReadLine();
                    Dispatch(delegate { poll.Start(); });
                    backend.WaitForExit();
                    backend.WaitForExit();
                    exitCode = backend.ExitCode;
                }
            }
            catch (Exception error) { failed = error; }
            Dispatch(delegate { CompleteOperation(exitCode, failed); });
        }

        private static DirectorySecurity AdminOnlySecurity()
        {
            DirectorySecurity security = new DirectorySecurity();
            security.SetAccessRuleProtection(true, false);
            security.SetOwner(new SecurityIdentifier(WellKnownSidType.BuiltinAdministratorsSid, null));
            foreach (WellKnownSidType type in new WellKnownSidType[] { WellKnownSidType.BuiltinAdministratorsSid, WellKnownSidType.LocalSystemSid })
            {
                SecurityIdentifier sid = new SecurityIdentifier(type, null);
                security.AddAccessRule(new FileSystemAccessRule(sid, FileSystemRights.FullControl, InheritanceFlags.ContainerInherit | InheritanceFlags.ObjectInherit, PropagationFlags.None, AccessControlType.Allow));
            }
            return security;
        }

        private static string CreateSecureRunDirectory()
        {
            // A new unpredictable, administrator-owned directory avoids trusting
            // a pre-existing user-owned staging root in writable ProgramData.
            string run = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData), "AlexandresWatchDogs2ShadowFlicker-" + Guid.NewGuid().ToString("N"));
            if (Directory.Exists(run) || File.Exists(run)) throw new IOException("The installer working directory already exists. Start the installer again.");
            Directory.CreateDirectory(run, AdminOnlySecurity());
            SecurityIdentifier owner = (SecurityIdentifier)new DirectoryInfo(run).GetAccessControl(AccessControlSections.Owner).GetOwner(typeof(SecurityIdentifier));
            if ((File.GetAttributes(run) & FileAttributes.ReparsePoint) != 0 || !owner.IsWellKnown(WellKnownSidType.BuiltinAdministratorsSid)) throw new IOException("The installer could not create a trusted administrator-owned working directory.");
            return run;
        }

        private void Dispatch(Action action)
        {
            if (IsDisposed || Disposing) return;
            try { BeginInvoke(action); } catch (InvalidOperationException) { }
        }

        private void ReadProgress()
        {
            if (progressPath == null || !File.Exists(progressPath)) return;
            try
            {
                Dictionary<string, object> data;
                using (FileStream stream = new FileStream(progressPath, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete))
                using (StreamReader reader = new StreamReader(stream, Encoding.UTF8))
                {
                    data = new JavaScriptSerializer().Deserialize<Dictionary<string, object>>(reader.ReadToEnd());
                }
                int value = Math.Max(0, Math.Min(100, Convert.ToInt32(data["Percent"])));
                string state = Convert.ToString(data["State"]);
                string currentMessage = Convert.ToString(data["Message"]);
                lastPercent = value;
                lastState = state;
                lastMessage = currentMessage;
                progress.Value = value;
                percent.Text = value.ToString() + "%";
                message.Text = currentMessage;
                cancel.Enabled = running && value < 75 && !cancellationRequested;
                if (running && value >= 75) footnote.Text = "Saving and verifying the profile. Please keep this window open.";
            }
            catch (IOException) { }
            catch (UnauthorizedAccessException) { }
            catch (ArgumentException) { }
            catch (KeyNotFoundException) { }
            catch (InvalidOperationException) { }
            catch (FormatException) { }
            catch (OverflowException) { }
        }

        private void RequestCancel()
        {
            if (!running) { Close(); return; }
            if (lastPercent >= 75 || cancellationRequested) return;
            cancellationRequested = true;
            cancel.Enabled = false;
            cancel.Text = "Cancelling...";
            footnote.Text = "Cancellation requested. Waiting for the current safe checkpoint.";
            AppendLog("Cancellation requested. The helper will not be terminated during a profile write.");
            try { if (cancellationPath != null) File.WriteAllText(cancellationPath, "cancel", Encoding.UTF8); }
            catch (IOException error) { AppendLog("Unable to send cancellation: " + error.Message); }
            catch (UnauthorizedAccessException error) { AppendLog("Unable to send cancellation: " + error.Message); }
        }

        private void OnClosing(object sender, FormClosingEventArgs e)
        {
            if (running) { e.Cancel = true; RequestCancel(); }
        }

        private void AppendLog(string line)
        {
            if (log.Length > 120000) log.Remove(0, 30000);
            log.AppendLine(line);
            details.Text = log.ToString();
            details.SelectionStart = details.TextLength;
            details.ScrollToCaret();
        }

        private void CompleteOperation(int exitCode, Exception error)
        {
            ReadProgress();
            poll.Stop();
            running = false;
            finished = true;
            next.Enabled = true;
            next.Text = "Finish";
            next.AccessibleName = "Finish";
            cancel.Visible = false;
            AcceptButton = next;
            CancelButton = null;
            if (error != null) AppendLog(error.Message);
            string outcome = InstallerResult.Classify(exitCode, error != null, lastState);
            bool succeeded = outcome == "Succeeded";
            bool cancelled = outcome == "Cancelled";
            if (succeeded)
            {
                progress.Value = 100;
                percent.Text = "100%";
                heading.Text = selectedAction == "Restore" ? "Original flag values restored" : selectedAction == "Status" ? "Profile check complete" : "The shadow fix is ready";
                message.Text = selectedAction == "Status" ? "The game-profile check is complete. Review the details below for the current flag values." : "The requested flag values were saved and verified. Start Watch Dogs 2 normally to check the shadows.";
                footnote.Text = "Backups: %LOCALAPPDATA%\\WatchDogs2FlickerFix";
            }
            else if (cancelled)
            {
                heading.Text = "Setup cancelled";
                message.Text = "The operation stopped at a safe checkpoint before changing the profile.";
                footnote.Text = "You can start the installer again whenever you are ready.";
            }
            else
            {
                heading.Text = "Setup could not complete";
                message.Text = error != null ? error.Message : lastMessage;
                footnote.Text = "Review the details below. Close the game before applying or undoing the fix.";
                if (error == null && lastState != "Failed") AppendLog("The helper exited without a verified success result (exit " + exitCode.ToString() + ").");
            }
            SaveAndCleanRunLog();
            next.Focus();
        }

        private void SaveAndCleanRunLog()
        {
            try
            {
                string logRoot = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "WatchDogs2FlickerFix", "InstallerLogs");
                Directory.CreateDirectory(logRoot);
                string path = Path.Combine(logRoot, DateTime.Now.ToString("yyyyMMdd-HHmmss") + "-" + Guid.NewGuid().ToString("N").Substring(0, 8) + ".log");
                File.WriteAllText(path, log.ToString(), Encoding.UTF8);
                AppendLog("Installer log: " + path);
            }
            catch (IOException error) { AppendLog("Could not save the installer log: " + error.Message); }
            catch (UnauthorizedAccessException error) { AppendLog("Could not save the installer log: " + error.Message); }
            if (runDirectory == null) return;
            try
            {
                string root = Path.GetFullPath(Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData));
                string run = Path.GetFullPath(runDirectory);
                string namePart = Path.GetFileName(run);
                const string prefix = "AlexandresWatchDogs2ShadowFlicker-";
                Guid runId;
                if (!String.Equals(Path.GetDirectoryName(run), root, StringComparison.OrdinalIgnoreCase) || !namePart.StartsWith(prefix, StringComparison.Ordinal) || !Guid.TryParseExact(namePart.Substring(prefix.Length), "N", out runId) || (File.GetAttributes(run) & FileAttributes.ReparsePoint) != 0) return;
                foreach (string name in new string[] { "WatchDogs2-FlickerFix.ps1", "progress.json", "progress.json.tmp", "cancellation.json" })
                {
                    string path = Path.Combine(run, name);
                    if (File.Exists(path)) File.Delete(path);
                }
                Directory.Delete(run, false);
            }
            catch (IOException) { }
            catch (UnauthorizedAccessException) { }
        }

        protected override void Dispose(bool disposing)
        {
            if (disposing) poll.Dispose();
            base.Dispose(disposing);
        }

        internal void SetPreview(string mode)
        {
            if (mode == "welcome") return;
            welcome.Visible = false;
            work.Visible = true;
            if (mode == "progress")
            {
                heading.Text = "Applying the shadow fix";
                message.Text = "Saving a backup of the original game-profile values...";
                progress.Value = 55;
                percent.Text = "55%";
                next.Enabled = false;
                footnote.Text = "Cancel stops at a safe checkpoint before profile changes begin.";
                AppendLog("Found Watch Dogs 2 in a Steam library.");
                AppendLog("Official dependency checksums verified.");
                AppendLog("Preparing the original flag-value backup.");
            }
            else
            {
                heading.Text = "The shadow fix is ready";
                message.Text = "The requested flag values were saved and verified. Start Watch Dogs 2 normally to check the shadows.";
                progress.Value = 100;
                percent.Text = "100%";
                next.Text = "Finish";
                cancel.Visible = false;
                footnote.Text = "Backups: %LOCALAPPDATA%\\WatchDogs2FlickerFix";
                AppendLog("0x00A4F311 = 0xA2B53761");
                AppendLog("0x00FC7620 = 0x00000001");
                AppendLog("Both game-profile values verified.");
            }
        }
    }

    public static class InstallerPreview
    {
        // Render-only QA hook. It never starts a helper or changes driver settings.
        public static void RenderScreenshots(string directory)
        {
            Application.EnableVisualStyles();
            Directory.CreateDirectory(directory);
            foreach (string mode in new string[] { "welcome", "progress", "complete", "compact" })
            {
                using (SetupForm form = new SetupForm())
                {
                    form.ShowInTaskbar = false;
                    form.Opacity = 0;
                    form.SetPreview(mode == "compact" ? "welcome" : mode);
                    form.Show();
                    if (mode == "compact") form.Size = new Size(900, 650);
                    Application.DoEvents();
                    using (Bitmap bitmap = new Bitmap(form.Width, form.Height))
                    {
                        form.DrawToBitmap(bitmap, new Rectangle(Point.Empty, form.Size));
                        bitmap.Save(Path.Combine(directory, mode + ".png"), System.Drawing.Imaging.ImageFormat.Png);
                    }
                    form.Close();
                }
            }
        }
    }
}
