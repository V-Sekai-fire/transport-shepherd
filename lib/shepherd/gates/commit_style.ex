defmodule Shepherd.Gates.CommitStyle do
  @moduledoc """
  Elixir port of `2-contract/manuals-weftspun/scripts/check_commit_style.py`.
  Same rules, same 12 self-test controls (6 subject, 4 through the CLI path
  on an own and a fork remote, 2 on a merged upstream commit).

  Commit subjects are sentence-case prose with no Conventional-Commits
  prefix on every repository we commit to, forks included (RFD 2026), so
  the gate reads no remote. Every commit reachable from HEAD and from
  neither `--base` nor any `--exclude` ref is checked for:

  1. No Conventional-Commits prefix (`^[a-z][a-z0-9-]*(\\([^)]+\\))?!?:`).
  2. First char uppercase / digit / bracket / backtick.
  3. No trailing period.

  Detection floor: none. Every subject is either ok or FAIL with the
  specific rule violated.
  """

  @conventional_rx ~r/^[a-z][a-z0-9-]*(\([^)]+\))?!?:/
  @sentence_start_rx ~r/^([A-Z]|\d|\[|`)/
  @trailing_period_rx ~r/\.$/
  @git_env Enum.map(
             ~w(GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY
                GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_PREFIX GIT_COMMON_DIR),
             &{&1, nil}
           )

  def run(["--self-test"]), do: self_test()

  def run(argv) do
    case OptionParser.parse(argv, strict: [base: :string, exclude: :keep]) do
      {opts, [], []} ->
        gate(opts[:base] || "HEAD~10", Keyword.get_values(opts, :exclude))

      _ ->
        IO.puts(:stderr, "usage: commit-style [--base <ref>] [--exclude <ref>]... | --self-test")
        2
    end
  end

  def check_subject(subject) do
    []
    |> maybe_add(Regex.match?(@conventional_rx, subject),
      "Conventional-Commits prefix (RFD 2026 says sentence-case prose)")
    |> maybe_add(not Regex.match?(@sentence_start_rx, subject),
      "first char not uppercase / digit / bracket")
    |> maybe_add(Regex.match?(@trailing_period_rx, subject),
      "trailing period")
  end

  defp maybe_add(list, false, _), do: list
  defp maybe_add(list, true, msg), do: list ++ [msg]

  defp git(args), do: System.cmd("git", args, env: @git_env, stderr_to_stdout: true)

  defp commits_in_range(base, excludes) do
    revs = ["HEAD" | Enum.map([base | excludes], &"^#{&1}")]

    case git(["log", "--format=%H\x1f%s" | revs] ++ ["--"]) do
      {out, 0} ->
        out
        |> String.split("\n", trim: true)
        |> Enum.flat_map(fn line ->
          case String.split(line, "\x1f", parts: 2) do
            [sha, subj] -> [{sha, subj}]
            _ -> []
          end
        end)

      {out, _} ->
        {:error, String.trim(out)}
    end
  end

  defp gate(base, excludes) do
    case commits_in_range(base, excludes) do
      {:error, msg} ->
        IO.puts("error: git log failed: #{msg}")
        2

      [] ->
        IO.puts("ok  0 commits in #{base}..HEAD")
        0

      commits ->
        failures =
          Enum.reduce(commits, 0, fn {sha, subj}, acc ->
            problems = check_subject(subj)

            if problems == [] do
              IO.puts("ok   #{String.slice(sha, 0, 12)}  #{String.slice(subj, 0, 60)}")
              acc
            else
              IO.puts("FAIL #{String.slice(sha, 0, 12)}  #{subj}")
              Enum.each(problems, &IO.puts("       - #{&1}"))
              acc + 1
            end
          end)

        IO.puts("---")
        IO.puts("#{length(commits)} commit(s), #{failures} failure(s)")
        if failures > 0, do: 1, else: 0
    end
  end

  defp commit(subject), do: ["commit", "-q", "--no-verify", "--allow-empty", "-m", subject]

  # Runs the gate the way `mix gates commit-style` does, from inside the scratch repository.
  defp run_on_scratch_repo(root, remote, steps, args) do
    repo = Path.join(root, "r#{System.unique_integer([:positive])}")
    File.mkdir_p!(repo)

    ident = ~w(-c user.name=self-test -c user.email=self-test@example.invalid
               -c commit.gpgsign=false)

    [["init", "-q", "-b", "work"], ["remote", "add", "origin", remote], commit("Base"),
     ["tag", "base"] | steps]
    |> Enum.each(fn step -> {_, 0} = git(["-C", repo | ident ++ step]) end)

    {:ok, io} = StringIO.open("")
    leader = Process.group_leader()
    Process.group_leader(self(), io)

    code =
      try do
        File.cd!(repo, fn -> Shepherd.Gates.dispatch(["commit-style" | args]) end)
      after
        Process.group_leader(self(), leader)
      end

    {_, out} = StringIO.contents(io)
    {code, out}
  end

  def self_test do
    subject_cases = [
      {"Add the macOS and Windows release workflows", 0, "plain sentence"},
      {"RFD 2026: Commit messages sentence case", 0, "RFD prefix, sentence body"},
      {"[urgent] Fix the leaking file descriptor", 0, "bracket-tag open"},
      {"feat: add the release workflow", 2, "conventional-commits + not-capital"},
      {"fix(parser): handle nested arrays", 2, "conventional-commits w/ scope + not-capital"},
      {"Add the workflow.", 1, "trailing period"}
    ]

    all_ok? =
      Enum.reduce(subject_cases, true, fn {subj, expect, label}, acc ->
        problems = check_subject(subj)
        ok = length(problems) == expect
        IO.puts("  #{if ok, do: "ok  ", else: "FAIL"} [#{label}] expect=#{expect} got=#{length(problems)}: #{subj}")
        unless ok do
          Enum.each(problems, &IO.puts("       problem: #{&1}"))
        end
        acc and ok
      end)

    fork = "https://github.com/godotengine/godot"

    upstream = [
      ["checkout", "-q", "-b", "upstream", "base"],
      commit("core: fix the scene loader"),
      ["checkout", "-q", "work"],
      commit("Add the release workflow"),
      ["merge", "-q", "--no-ff", "--no-verify", "-m", "Merge the upstream", "upstream"]
    ]

    runs =
      for remote <- ["https://github.com/V-Sekai-fire/manuals-weftspun", fork],
          {subj, expect} <- [{"feat: add the release workflow", 1}, {"Add the release workflow", 0}] do
        {"remote #{remote} subject #{inspect(subj)}", remote, [commit(subj)],
         ["--base", "HEAD~1"], expect, subj}
      end

    runs =
      runs ++
        [
          {"merged upstream prefixed commit read", fork, upstream, ["--base", "base"], 1,
           "core: fix the scene loader"},
          {"merged upstream prefixed commit excluded", fork, upstream,
           ["--base", "base", "--exclude", "upstream"], 0, ""}
        ]

    root = Path.join(System.tmp_dir!(), "commit-style-#{System.unique_integer([:positive])}")

    all_ok? =
      try do
        Enum.reduce(runs, all_ok?, fn {label, remote, steps, args, expect, failing}, acc ->
          {got, out} = run_on_scratch_repo(root, remote, steps, args)

          named =
            out
            |> String.split("\n")
            |> Enum.any?(&(String.starts_with?(&1, "FAIL ") and String.ends_with?(&1, "  #{failing}")))

          ok = got == expect and (expect == 0 or named)
          IO.puts("  #{if ok, do: "ok  ", else: "FAIL"} #{label} exit=#{got} (expected #{expect})")
          acc and ok
        end)
      after
        File.rm_rf!(root)
      end

    IO.puts("---")
    IO.puts("self-test: #{if all_ok?, do: "ok", else: "FAIL"}")
    if all_ok?, do: 0, else: 1
  end
end
