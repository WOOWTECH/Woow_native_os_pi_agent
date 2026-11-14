using System;
using System.Reflection;
using System.Windows.Forms;

// Compile alongside Launcher.cs with /main:LauncherTests. No WSL changes.
internal static class LauncherTests
{
    private static int count;
    private static void Check(bool condition, string name)
    {
        if (!condition) throw new Exception(name);
        Console.WriteLine("PASS: " + name); count++;
    }
    private static T Field<T>(InstallerForm form, string name)
    {
        return (T)typeof(InstallerForm).GetField(name, BindingFlags.NonPublic | BindingFlags.Instance).GetValue(form);
    }
    [STAThread]
    private static int Main(string[] args)
    {
        // Windows signing suite exercises the real GUI child's redirection and
        // signature/byte-lock guard without clicking through the form.
        if (args.Length > 0 && args[0] == "--run-installer")
        {
            var forwarded = new string[args.Length - 1];
            Array.Copy(args, 1, forwarded, 0, forwarded.Length);
            return Launcher.RunInstaller(Launcher.PrepareGuiArguments(forwarded), Console.WriteLine);
        }
        foreach (string yes in new[] { "-Y", "-Ye", "-Yes", "-y", "-yE", "-YES" })
        {
            string[] original = new[] { "-BundlePath", @"C:\QA assets\candidate.tar.gz", yes };
            string[] actual = Launcher.PrepareGuiArguments(original);
            Check(String.Join("|", actual) == String.Join("|", original), "GUI preserves " + yes + " without duplicate Yes");
        }
        string[] added = Launcher.PrepareGuiArguments(new[] { "-DryRun" });
        Check(added.Length == 2 && added[0] == "-DryRun" && added[1] == "-Yes", "GUI adds Yes when absent");
        Check(Launcher.PrepareGuiArguments(new string[0])[0] == "-Yes", "default GUI adds Yes");
        Check(InstallerForm.ValidLocalUrl("http://localhost:43210/") == "http://localhost:43210/", "nondefault port is preserved");
        foreach (string url in new[] { "https://localhost:43210/", "http://example.com:43210/", "file:///C:/test", "http://localhost:80/", "http://user@localhost:43210/", "http://localhost:43210/?x=1", "http://localhost:43210/path", "broken" })
            Check(InstallerForm.ValidLocalUrl(url) == null, "reject unexpected URL: " + url);
        using (var form = new InstallerForm(new[] { "-Yes" }))
        {
            Check(form.ExitCode == 2, "closing before start reports cancellation");
            Check(!Field<Button>(form, "open").Enabled, "cannot open before installation");
            form.ReceiveLine("[PiAgent:step]stage 4/6: install");
            Check(Field<ProgressBar>(form, "progress").Value == 4, "real stage updates progress");
            Check(Field<Label>(form, "status").Text.Contains("4/6"), "real stage updates status");
            form.ReceiveLine("[PiAgent:ready]http://localhost:43210/");
            form.Complete(70);
            Check(!Field<Button>(form, "open").Enabled && Field<Button>(form, "start").Enabled, "failed verification permits retry but not opening");
            Check(form.ExitCode == 70, "failure exit code preserved");
            form.Complete(20);
            Check(Field<Label>(form, "status").Text.Contains("20") && !Field<Button>(form, "open").Enabled, "reboot is distinct from success");
            form.Complete(0);
            Check(Field<Button>(form, "open").Enabled && !Field<Button>(form, "start").Enabled, "verified success enables opening only");
            Check(Field<ProgressBar>(form, "progress").Value == 7, "only success completes progress");
        }
        using (var form = new InstallerForm(new[] { "-DryRun", "-Yes" }))
        {
            form.ReceiveLine("[PiAgent:ready]http://localhost:43210/");
            form.Complete(0);
            Check(!Field<Button>(form, "open").Enabled, "dry run cannot open browser even with ready output");
        }
        using (var form = new InstallerForm(new[] { "-Yes" }))
        {
            form.Complete(0);
            Check(!Field<Button>(form, "open").Enabled, "missing endpoint is never guessed");
        }
        Console.WriteLine(count + " launcher checks passed");
        return 0;
    }
}
