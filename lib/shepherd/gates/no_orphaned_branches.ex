defmodule Shepherd.Gates.NoOrphanedBranches do
  @moduledoc """
  Elixir port of `2-contract/manuals-weftspun/scripts/check_no_orphaned_branches.py`.
  Same rules, same 6 self-test controls.

  A remote branch is an orphan when its PR merged, no open PR reopened it,
  and it carries no commits ahead of the default branch. `delete_branch_on_merge`
  handles the common case; this gate backstops a branch pushed to after its
  PR merged.

  Detection floor: none. Every remote branch enumerated by `gh api` is
  classified against merged/opened/ahead-of-base and returns ok or FAIL.
  """

  @excluded MapSet.new(~w(main gh-pages))
  @default_repo "V-Sekai-fire/manuals-weftspun"

  def run(["--self-test"]), do: self_test()

  def run(argv) do
    repo =
      case Enum.find_index(argv, &(&1 == "--repo")) do
        nil -> @default_repo
        i -> Enum.at(argv, i + 1)
      end
    base =
      case Enum.find_index(argv, &(&1 == "--base")) do
        nil -> "main"
        i -> Enum.at(argv, i + 1)
      end
    gate(repo, base)
  end

  def is_orphan?(branch, merged, opened, ahead, excluded \\ @excluded) do
    cond do
      MapSet.member?(excluded, branch) -> false
      not MapSet.member?(merged, branch) -> false
      MapSet.member?(opened, branch) -> false
      ahead > 0 -> false
      true -> true
    end
  end

  defp remote_branches(repo) do
    {out, 0} = System.cmd("gh",
      ["api", "repos/#{repo}/branches", "--paginate", "--jq", ".[].name"])
    String.split(out, "\n", trim: true)
  end

  defp pr_heads(repo, state) do
    {out, 0} = System.cmd("gh",
      ["pr", "list", "--repo", repo, "--state", state, "--limit", "500",
       "--json", "headRefName"])
    out
    |> Jason.decode!()
    |> Enum.map(& &1["headRefName"])
    |> MapSet.new()
  end

  defp ahead_of(repo, base, branch) do
    {out, 0} = System.cmd("gh",
      ["api", "repos/#{repo}/compare/#{base}...#{branch}", "--jq", ".ahead_by"])
    case String.trim(out) do
      "" -> 0
      s -> String.to_integer(s)
    end
  end

  defp gate(repo, base) do
    branches = remote_branches(repo)
    merged = pr_heads(repo, "merged")
    opened = pr_heads(repo, "open")

    orphans =
      branches
      |> Enum.sort()
      |> Enum.filter(fn b ->
        cond do
          MapSet.member?(@excluded, b) -> false
          not MapSet.member?(merged, b) -> false
          MapSet.member?(opened, b) -> false
          true -> is_orphan?(b, merged, opened, ahead_of(repo, base, b))
        end
      end)

    if orphans != [] do
      IO.puts("FAIL #{length(orphans)} merged PR(s) with an orphaned head branch:")
      Enum.each(orphans, &IO.puts("       #{&1}"))
      IO.puts("")
      IO.puts("     delete each with: git push origin --delete <branch>")
      1
    else
      IO.puts("ok   #{length(branches)} branch(es), no orphans.")
      0
    end
  end

  def self_test do
    ex = MapSet.new(["main"])
    m = MapSet.new(~w(x y z main))
    o = MapSet.new(["y"])

    checks = [
      {"a merged branch with no open PR and no ahead commits is an orphan",
        is_orphan?("x", m, o, 0, ex) == true},
      {"a merged branch reopened as an open PR is not an orphan",
        is_orphan?("y", m, o, 0, ex) == false},
      {"a merged branch with commits ahead of main is not an orphan",
        is_orphan?("z", m, o, 5, ex) == false},
      {"a branch with no PR at all is not an orphan",
        is_orphan?("n", MapSet.new(), MapSet.new(), 0, ex) == false},
      {"main is never an orphan",
        is_orphan?("main", m, o, 0, ex) == false},
      {"an open-only branch is not an orphan",
        is_orphan?("y", MapSet.new(), o, 0, ex) == false}
    ]

    IO.puts("")
    Enum.each(checks, fn {name, ok} ->
      IO.puts("  #{if ok, do: "ok  ", else: "FAIL"} control: #{name}")
    end)
    bad = Enum.count(checks, fn {_, ok} -> not ok end)
    IO.puts("  #{length(checks) - bad} of #{length(checks)} controls fired.")
    if bad > 0, do: 1, else: 0
  end
end
