defmodule Shepherd.Gates.CommitStyle do
  @moduledoc """
  Elixir port of `2-contract/manuals-weftspun/scripts/check_commit_style.py`.
  Same rules, same 10 self-test controls (6 subject + 4 url-classify).

  Commit subjects on weftspun-owned repos are sentence-case prose, no
  Conventional-Commits prefix. Forks are skipped (RFD 2026). Every commit
  in `base..HEAD` is checked for:

  1. No Conventional-Commits prefix (`^[a-z][a-z0-9-]*(\\([^)]+\\))?!?:`).
  2. First char uppercase / digit / bracket / backtick.
  3. No trailing period.

  Detection floor: none. Every subject is either ok or FAIL with the
  specific rule violated.
  """

  @conventional_rx ~r/^[a-z][a-z0-9-]*(\([^)]+\))?!?:/
  @sentence_start_rx ~r/^([A-Z]|\d|\[|`)/
  @trailing_period_rx ~r/\.$/
  @own_rx ~r"github\.com[/:](V-Sekai-fire|chibifire-stages)/"i

  def run(["--self-test"]), do: self_test()

  def run(argv) do
    base =
      case Enum.find_index(argv, &(&1 == "--base")) do
        nil -> "HEAD~10"
        i -> Enum.at(argv, i + 1)
      end
    if not own_repo?(File.cwd!()) do
      IO.puts("skipped: origin not ours (fork convention applies, RFD 2026)")
      0
    else
      gate(base)
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

  def own_repo?(cwd) do
    case System.cmd("git", ["-C", cwd, "config", "--get-regexp", "^remote\\..*\\.url$"],
                    stderr_to_stdout: true) do
      {out, 0} ->
        out
        |> String.split("\n", trim: true)
        |> Enum.any?(fn line ->
          case String.split(line, ~r/\s+/, parts: 2) do
            [_, url] -> Regex.match?(@own_rx, url)
            _ -> false
          end
        end)
      _ -> false
    end
  end

  defp commits_in_range(base) do
    {out, 0} =
      System.cmd("git", ["log", "--format=%H\x1f%s", "#{base}..HEAD"])
    out
    |> String.split("\n", trim: true)
    |> Enum.flat_map(fn line ->
      case String.split(line, "\x1f", parts: 2) do
        [sha, subj] -> [{sha, subj}]
        _ -> []
      end
    end)
  end

  defp gate(base) do
    commits = commits_in_range(base)
    if commits == [] do
      IO.puts("ok  0 commits in #{base}..HEAD")
      0
    else
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

  def self_test do
    subject_cases = [
      {"Add the macOS and Windows release workflows", 0, "plain sentence"},
      {"RFD 2026: Commit messages sentence case", 0, "RFD prefix, sentence body"},
      {"[urgent] Fix the leaking file descriptor", 0, "bracket-tag open"},
      {"feat: add the release workflow", 2, "conventional-commits + not-capital"},
      {"fix(parser): handle nested arrays", 2, "conventional-commits w/ scope + not-capital"},
      {"Add the workflow.", 1, "trailing period"}
    ]

    url_cases = [
      {"https://github.com/V-Sekai-fire/manuals-weftspun", true},
      {"git@github.com:V-Sekai-fire/interactor-dress-on.git", true},
      {"https://github.com/v-sekai-fire/interactor-dress-on", true},
      {"https://github.com/chibifire-stages/character-marocchino", true},
      {"https://github.com/godotengine/godot", false},
      {"git@github.com:huggingface/transformers.git", false},
      {"https://github.com/weftspun/request-for-discussion", false},
      {"https://github.com/V-Sekai-fire-mirror/manuals-weftspun", false}
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

    all_ok? =
      Enum.reduce(url_cases, all_ok?, fn {url, expect_own}, acc ->
        got_own = Regex.match?(@own_rx, url)
        ok = got_own == expect_own
        IO.puts("  #{if ok, do: "ok  ", else: "FAIL"} url-classify #{inspect(url)} → own=#{got_own} (expected #{expect_own})")
        acc and ok
      end)

    IO.puts("---")
    IO.puts("self-test: #{if all_ok?, do: "ok", else: "FAIL"}")
    if all_ok?, do: 0, else: 1
  end
end
