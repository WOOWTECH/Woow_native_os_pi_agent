using System;
using System.Diagnostics;
using System.IO;
using System.Text;

// Built with the signed, version-stamped installer embedded as an assembly resource.
// No script is downloaded or interpreted before its Authenticode signature is checked.
internal static class Launcher
{
    private static string Literal(string value) { return "'" + value.Replace("'", "''") + "'"; }

    private static int Main(string[] args)
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
                string command = "$ErrorActionPreference='Stop'; try { $p=" + Literal(path) +
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
                var start = new ProcessStartInfo(shell, "-NoProfile -OutputFormat Text -ExecutionPolicy Bypass -EncodedCommand " +
                    Convert.ToBase64String(Encoding.Unicode.GetBytes(command)));
                // Bypass avoids a separate TrustedPublisher prompt. Our explicit check above is mandatory.
                start.UseShellExecute = false;
                // PowerShell 7 passes its own module path to native children. The
                // installer uses Windows PowerShell inbox modules, not PS7 assemblies.
                start.EnvironmentVariables["PSModulePath"] = Path.Combine(Path.GetDirectoryName(shell), "Modules");
                using (Process process = Process.Start(start)) { process.WaitForExit(); code = process.ExitCode; }
            }
        }
        catch (Exception error) { Console.Error.WriteLine(error.Message); }
        finally { try { Directory.Delete(dir, true); } catch { } }
        if (args.Length == 0 && !Console.IsInputRedirected)
        {
            Console.WriteLine("Press Enter to close this window.");
            Console.ReadLine();
        }
        return code;
    }
}
