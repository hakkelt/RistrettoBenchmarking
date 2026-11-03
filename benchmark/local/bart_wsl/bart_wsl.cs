// bart.exe for Windows: runs a BART built inside WSL, so the comparison suite can time it through
// RISTRETTO_BENCH_BART_OPENBLAS like a native build. BART ships no native Windows build; its MSYS2
// path loses FFTW's threads.
//
// RISTRETTO_BENCH_BART_WSL names the build as <distro>:<path of bart inside it>, e.g.
//   RISTRETTO_BENCH_BART_WSL=Ubuntu:/home/me/bart/bart-openblas/bart
// A file bart_wsl.target next to bart.exe, holding the same <distro>:<path> on one line, takes
// precedence: that is how a second build (the CUDA one, RISTRETTO_BENCH_BART_CUDA) gets a bart.exe of
// its own beside the OpenBLAS one.
// Every argument that is a Windows path (X:\... or X:/...) becomes /mnt/x/...; bart_wsl.sh, next to
// this file, stages those files on the WSL file system around the run (see there why). OpenMP,
// OpenBLAS and BART settings are forwarded through WSLENV, BART_TOOLBOX_PATH translated as a path.
// The exit status is BART's.
//
// Not covered by the process affinity mask run_comparison.ps1 sets: BART runs in the WSL 2 VM,
// whose virtual CPUs the Windows scheduler places on any core, SMT siblings included.
//
// Build with Windows PowerShell 5.1 (the .NET Framework compiler), then put bart_wsl.sh next to it:
//   Add-Type -Path benchmark\local\bart_wsl\bart_wsl.cs -OutputType ConsoleApplication -OutputAssembly D:\bart\wsl-openblas\bart.exe
//   Copy-Item benchmark\local\bart_wsl\bart_wsl.sh D:\bart\wsl-openblas\
// and for the CUDA build, the same two steps into D:\bart\wsl-cuda\ plus its target file:
//   Set-Content D:\bart\wsl-cuda\bart_wsl.target 'Ubuntu:/home/me/bart/bart-cuda/bart'
using System;
using System.Diagnostics;
using System.IO;
using System.Text;
using System.Text.RegularExpressions;

static class BartWsl
{
    const string Forward = "OMP_NUM_THREADS/u:OPENBLAS_NUM_THREADS/u:OMP_PROC_BIND/u:OMP_PLACES/u:" +
        "BART_USE_FFTW_WISDOM/u:BART_TOOLBOX_PATH/pu:BART_DEBUG_LEVEL/u:DEBUG_LEVEL/u";

    static string ToWsl(string a)
    {
        var m = Regex.Match(a, @"^([A-Za-z]):[\\/](.*)$");
        if (!m.Success) return a;
        return "/mnt/" + char.ToLowerInvariant(m.Groups[1].Value[0]) + "/" + m.Groups[2].Value.Replace('\\', '/');
    }

    // Quoting for CommandLineToArgvW, which wsl.exe parses its command line with.
    static string Quote(string s)
    {
        if (s.Length > 0 && s.IndexOfAny(new[] { ' ', '\t', '"' }) < 0) return s;
        var sb = new StringBuilder("\"");
        int slashes = 0;
        foreach (char c in s)
        {
            if (c == '\\') { slashes++; continue; }
            if (c == '"') sb.Append('\\', 2 * slashes + 1);
            else sb.Append('\\', slashes);
            slashes = 0;
            sb.Append(c);
        }
        sb.Append('\\', 2 * slashes).Append('"');
        return sb.ToString();
    }

    static int Main(string[] args)
    {
        string targetFile = Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "bart_wsl.target");
        string target = File.Exists(targetFile)
            ? File.ReadAllText(targetFile).Trim()
            : Environment.GetEnvironmentVariable("RISTRETTO_BENCH_BART_WSL") ?? "";
        int colon = target.IndexOf(':');
        if (colon <= 0 || colon == target.Length - 1)
        {
            Console.Error.WriteLine("bart.exe: put <distro>:<path of bart in WSL> in " + targetFile +
                " or in RISTRETTO_BENCH_BART_WSL");
            return 2;
        }
        string distro = target.Substring(0, colon), bart = target.Substring(colon + 1);
        string script = ToWsl(Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "bart_wsl.sh"));

        var cmd = new StringBuilder();
        cmd.Append("-d ").Append(Quote(distro)).Append(" --exec bash ").Append(Quote(script)).Append(' ').Append(Quote(bart));
        foreach (string a in args) cmd.Append(' ').Append(Quote(ToWsl(a)));

        var psi = new ProcessStartInfo("wsl.exe", cmd.ToString()) { UseShellExecute = false };
        // Only what is set: WSLENV passes an unset name as an empty value, which libgomp rejects.
        var env = new StringBuilder(Environment.GetEnvironmentVariable("WSLENV") ?? "");
        foreach (string f in Forward.Split(':'))
        {
            if (string.IsNullOrEmpty(Environment.GetEnvironmentVariable(f.Split('/')[0]))) continue;
            if (env.Length > 0) env.Append(':');
            env.Append(f);
        }
        psi.EnvironmentVariables["WSLENV"] = env.ToString();
        using (var p = Process.Start(psi))
        {
            p.WaitForExit();
            return p.ExitCode;
        }
    }
}
