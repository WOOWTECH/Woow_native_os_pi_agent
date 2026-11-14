using System;
using System.Diagnostics;
using System.IO;
using System.Text;
using System.Collections.Generic;
using System.Drawing;
using System.Runtime.InteropServices;
using System.Threading;
using System.Windows.Forms;

// Built with the signed, version-stamped installer embedded as an assembly resource.
// No script is downloaded or interpreted before its Authenticode signature is checked.
internal static class Launcher
{
    private static string Literal(string value) { return "'" + value.Replace("'", "''") + "'"; }

    [DllImport("kernel32.dll")] private static extern uint GetConsoleProcessList(uint[] list, uint count);
    [DllImport("kernel32.dll")] private static extern bool FreeConsole();

    [STAThread]
    private static int Main(string[] args)
    {
        bool gui = args.Length == 0;
        var forwarded = new List<string>();
        foreach (string arg in args)
        {
            if (String.Equals(arg, "-Gui", StringComparison.OrdinalIgnoreCase)) gui = true;
            else forwarded.Add(arg);
        }
        if (!gui) return RunInstaller(args, null);
        // Never hide/detach a caller's shared console. Keep /target:exe so shells
        // wait and capture CLI output/exit codes just as they did before the GUI.
        if (GetConsoleProcessList(new uint[2], 2) == 1) FreeConsole();
        Application.EnableVisualStyles();
        Application.SetCompatibleTextRenderingDefault(false);
        foreach (string arg in forwarded)
        {
            // PowerShell accepts unambiguous parameter abbreviations, too.
            string name = arg.TrimStart('-').Split(':')[0];
            if (arg.StartsWith("-") && name.Length > 0 &&
                ("Uninstall".StartsWith(name, StringComparison.OrdinalIgnoreCase) ||
                 "PurgeData".StartsWith(name, StringComparison.OrdinalIgnoreCase)))
            {
                MessageBox.Show("圖形模式僅支援安裝。解除安裝或刪除資料請移除 -Gui，使用命令列確認。",
                    "Pi Agent", MessageBoxButtons.OK, MessageBoxIcon.Warning);
                return 2;
            }
        }
        // The user explicitly starts the installation in the form. -Yes never
        // consents to reboot in install-wsl.ps1. NonInteractive fails unexpected
        // prompts instead of leaving an invisible Read-Host waiting forever.
        using (var form = new InstallerForm(PrepareGuiArguments(forwarded.ToArray())))
        {
            Application.Run(form);
            return form.ExitCode;
        }
    }

    internal static string[] PrepareGuiArguments(string[] args)
    {
        var forwarded = new List<string>(args);
        // PowerShell binds -Y and -Ye to -Yes; adding the long name again is
        // a duplicate parameter error. Preserve the user's spelling and values.
        if (!forwarded.Exists(a => String.Equals(a, "-Y", StringComparison.OrdinalIgnoreCase) ||
                                   String.Equals(a, "-Ye", StringComparison.OrdinalIgnoreCase) ||
                                   String.Equals(a, "-Yes", StringComparison.OrdinalIgnoreCase)))
            forwarded.Add("-Yes");
        return forwarded.ToArray();
    }

    internal static int RunInstaller(string[] args, Action<string> output)
    {
        int code = 1;
        string dir = Path.Combine(Path.GetTempPath(), "PiAgent-" + Guid.NewGuid().ToString("N"));
        try
        {
            Directory.CreateDirectory(dir);
            string path = Path.Combine(dir, "install-wsl.ps1");
            using (Stream resource = typeof(Launcher).Assembly.GetManifestResourceStream("install-wsl.ps1"))
            using (FileStream file = new FileStream(path, FileMode.CreateNew, FileAccess.Write, FileShare.None))
                resource.CopyTo(file);

            // Keep the verified bytes unchanged until PowerShell exits (no write/delete sharing).
            using (FileStream held = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read))
            {
                string command = (output == null ? "" : "[Console]::OutputEncoding=New-Object Text.UTF8Encoding($false); ") + "$ErrorActionPreference='Stop'; try { $p=" + Literal(path) +
                    "; $s=Get-AuthenticodeSignature -LiteralPath $p; " +
                    "if ($s.Status -ne 'Valid' -or $s.SignerCertificate.GetNameInfo(" +
                    "[Security.Cryptography.X509Certificates.X509NameType]::SimpleName,$false) -cne " +
                    Literal("@@PUBLISHER@@") + ") { throw 'Installer signature or publisher is invalid' }; & $p";
                // Native argv is preserved, including spaces, quotes, and PowerShell metacharacters.
                // Parameter names are accepted only as literal switches; values are quoted.
                foreach (string arg in args)
                {
                    if (System.Text.RegularExpressions.Regex.IsMatch(arg, "^-[A-Za-z][A-Za-z0-9]*$"))
                        command += " " + arg;
                    else
                        command += " " + Literal(arg);
                }
                command += "; exit $LASTEXITCODE } catch { Write-Error $_; exit 1 }";
                string shell = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System),
                    @"WindowsPowerShell\v1.0\powershell.exe");
                string encoded = Convert.ToBase64String(Encoding.Unicode.GetBytes(command));
                // Windows PowerShell serializes redirected stderr as CLIXML for
                // -EncodedCommand, even with -OutputFormat Text. A text -Command
                // bootstrap avoids that special mode. Only base64 is interpolated;
                // native arguments still pass through Literal and the same guard.
                string invocation = output == null ? "-EncodedCommand " + encoded :
                    "-Command \"& ([ScriptBlock]::Create([Text.Encoding]::Unicode.GetString([Convert]::FromBase64String('" + encoded + "'))))\"";
                var start = new ProcessStartInfo(shell, (output == null ? "" : "-NonInteractive ") +
                    "-NoProfile -OutputFormat Text -ExecutionPolicy Bypass " + invocation);
                // Bypass avoids a separate TrustedPublisher prompt. Our explicit check above is mandatory.
                start.UseShellExecute = false;
                // PowerShell 7 passes its own module path to native children. The
                // installer uses Windows PowerShell inbox modules, not PS7 assemblies.
                start.EnvironmentVariables["PSModulePath"] = Path.Combine(Path.GetDirectoryName(shell), "Modules");
                if (output != null)
                {
                    start.CreateNoWindow = true;
                    start.RedirectStandardOutput = true;
                    start.RedirectStandardError = true;
                    start.RedirectStandardInput = true;
                    start.StandardOutputEncoding = Encoding.UTF8;
                    start.StandardErrorEncoding = Encoding.UTF8;
                    start.EnvironmentVariables["PI_AGENT_LAUNCHER_GUI"] = "1";
                }
                else start.EnvironmentVariables.Remove("PI_AGENT_LAUNCHER_GUI");
                using (Process process = new Process())
                {
                    process.StartInfo = start;
                    if (output != null)
                    {
                        process.OutputDataReceived += (sender, e) => { if (e.Data != null) output(e.Data); };
                        process.ErrorDataReceived += (sender, e) => { if (e.Data != null) output(e.Data); };
                    }
                    process.Start();
                    if (output != null)
                    {
                        process.StandardInput.Close();
                        process.BeginOutputReadLine();
                        process.BeginErrorReadLine();
                    }
                    process.WaitForExit(); // also drains asynchronous output before releasing the byte lock
                    code = process.ExitCode;
                }
            }
        }
        catch (Exception error) { if (output == null) Console.Error.WriteLine(error.Message); else output(error.ToString()); }
        finally { try { Directory.Delete(dir, true); } catch { } }
        return code;
    }
}

// All controls are updated on the STA UI thread; the signed installer runs on a worker.
internal sealed class InstallerForm : Form
{
    private readonly string[] arguments;
    private readonly Label status = new Label();
    private readonly ProgressBar progress = new ProgressBar();
    private readonly TextBox details = new TextBox();
    private readonly Button start = new Button();
    private readonly Button open = new Button();
    private readonly Button logs = new Button();
    private readonly Button close = new Button();
    private bool running;
    private string readyUrl;
    private string logPath;
    internal int ExitCode = 2;

    internal InstallerForm(string[] args)
    {
        arguments = args;
        Text = "Pi Agent 安裝程式";
        ClientSize = new Size(760, 540);
        MinimumSize = new Size(650, 450);
        StartPosition = FormStartPosition.CenterScreen;
        Font = new Font("Microsoft JhengHei UI", 10);
        var layout = new TableLayoutPanel { Dock = DockStyle.Fill, Padding = new Padding(16), RowCount = 5, ColumnCount = 1 };
        layout.RowStyles.Add(new RowStyle(SizeType.Absolute, 105));
        layout.RowStyles.Add(new RowStyle(SizeType.Absolute, 50));
        layout.RowStyles.Add(new RowStyle(SizeType.Absolute, 28));
        layout.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
        layout.RowStyles.Add(new RowStyle(SizeType.Absolute, 48));
        var intro = new Label { Dock = DockStyle.Fill, Text = "安裝 Pi Agent 與專用的 WSL2 Linux，並設定登入時啟動。\r\n需要網路與至少 10 GB 可用空間；首次啟用 WSL 可能要求系統管理員授權。\r\n若需要重新開機，請儲存工作後自行重新開機。本程式不會自動重開機。\r\n按「開始」即依指定選項安裝；-DryRun 僅檢查。" };
        status.Dock = DockStyle.Fill;
        status.Text = "準備就緒。安裝期間可在下方查看詳細紀錄。";
        progress.Dock = DockStyle.Fill;
        progress.Maximum = 7;
        details.Dock = DockStyle.Fill;
        details.Multiline = true;
        details.ReadOnly = true;
        details.ScrollBars = ScrollBars.Both;
        details.WordWrap = false;
        var buttons = new FlowLayoutPanel { Dock = DockStyle.Fill, AutoSize = true };
        start.Text = "開始"; open.Text = "開啟本機網頁"; logs.Text = "查看 log"; close.Text = "關閉";
        foreach (Button button in new[] { start, open, logs, close }) { button.AutoSize = true; buttons.Controls.Add(button); }
        open.Enabled = false; logs.Enabled = false;
        start.Click += (s, e) => BeginInstall();
        open.Click += (s, e) => OpenDocument(readyUrl);
        logs.Click += (s, e) => OpenDocument(logPath);
        close.Click += (s, e) => Close();
        FormClosing += (s, e) => {
            if (running) { e.Cancel = true; MessageBox.Show(this, "安裝正在進行，請等待完成。詳細進度與錯誤會顯示在視窗中。", Text); }
        };
        layout.Controls.Add(intro); layout.Controls.Add(status); layout.Controls.Add(progress);
        layout.Controls.Add(details); layout.Controls.Add(buttons);
        Controls.Add(layout);
    }

    private void OpenDocument(string path)
    {
        if (String.IsNullOrEmpty(path)) return;
        try { Process.Start(new ProcessStartInfo(path) { UseShellExecute = true }); }
        catch (Exception error) { MessageBox.Show(this, error.Message, Text, MessageBoxButtons.OK, MessageBoxIcon.Error); }
    }

    private void BeginInstall()
    {
        if (running) return;
        StreamWriter log;
        try
        {
            string dir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "PiAgent", "launcher-logs");
            Directory.CreateDirectory(dir);
            logPath = Path.Combine(dir, DateTime.Now.ToString("yyyyMMdd-HHmmss") + "-" + Guid.NewGuid().ToString("N") + ".log");
            log = new StreamWriter(new FileStream(logPath, FileMode.CreateNew, FileAccess.Write, FileShare.Read), Encoding.UTF8);
            log.AutoFlush = true;
        }
        catch (Exception error) { MessageBox.Show(this, "無法建立安裝紀錄：" + error.Message, Text); return; }
        running = true; readyUrl = null; ExitCode = 1;
        start.Enabled = false; open.Enabled = false; close.Enabled = false; logs.Enabled = true;
        details.Clear(); progress.Value = 0; progress.Style = ProgressBarStyle.Marquee;
        status.Text = "正在驗證安裝程式簽章…";
        var worker = new Thread(() => {
            object gate = new object();
            Action<string> output = line => {
                lock (gate)
                {
                    // Disk-full errors must not terminate the installer or its pipe reader.
                    try { log.WriteLine(line); } catch (IOException) { }
                    BeginInvoke((Action)(() => ReceiveLine(line)));
                }
            };
            int code = Launcher.RunInstaller(arguments, output);
            try { log.Dispose(); } catch (IOException) { }
            BeginInvoke((Action)(() => Complete(code)));
        });
        worker.IsBackground = true;
        worker.Start();
    }

    internal void ReceiveLine(string line)
    {
        const string step = "[PiAgent:step]";
        const string ready = "[PiAgent:ready]";
        if (line.StartsWith(step, StringComparison.Ordinal))
        {
            status.Text = line.Substring(step.Length);
            var match = System.Text.RegularExpressions.Regex.Match(status.Text, @"(\d)/6");
            if (match.Success)
            {
                progress.Style = ProgressBarStyle.Continuous;
                progress.Value = Math.Min(6, Int32.Parse(match.Groups[1].Value));
            }
        }
        if (line.StartsWith(ready, StringComparison.Ordinal))
            readyUrl = ValidLocalUrl(line.Substring(ready.Length));
        // Bound the visible buffer; the full output stays in the persistent log.
        if (details.TextLength > 200000) details.Text = details.Text.Substring(details.TextLength - 100000);
        details.AppendText(line + Environment.NewLine);
    }

    internal static string ValidLocalUrl(string text)
    {
        Uri uri;
        if (!Uri.TryCreate(text, UriKind.Absolute, out uri) || uri.Scheme != "http" ||
            uri.Host != "localhost" || uri.Port < 1024 || uri.Port > 65535 ||
            uri.UserInfo.Length != 0 || uri.AbsolutePath != "/" || uri.Query.Length != 0 || uri.Fragment.Length != 0)
            return null;
        return uri.AbsoluteUri;
    }

    internal void Complete(int code)
    {
        running = false; ExitCode = code;
        close.Enabled = true;
        progress.Style = ProgressBarStyle.Continuous;
        bool dry = Array.Exists(arguments, a => String.Equals(a, "-DryRun", StringComparison.OrdinalIgnoreCase));
        open.Enabled = code == 0 && !dry && readyUrl != null;
        start.Enabled = code != 0;
        start.Text = "重試";
        if (code == 0)
        {
            progress.Value = 7;
            status.Text = dry ? "檢查完成，未執行安裝。" : "安裝完成。可按「開啟本機網頁」開始使用。";
            if (!dry && readyUrl == null) status.Text = "安裝程式已完成，未回報本機網址。請查看 log。";
        }
        else if (code == 20)
            status.Text = "需要重新開機（20）。請儲存工作後自行重新開機；登入後以相同參數再次開啟此安裝程式。";
        else status.Text = "安裝未完成（結束碼 " + code + "）。請查看 log，處理原因後按「重試」。";
    }
}
