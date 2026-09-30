defmodule Shepherd.Gates.GoalManifests do
  @moduledoc """
  Elixir port of `2-contract/manuals-weftspun/scripts/check_goal_manifests.py`.
  Same rules, same 2 self-test controls.

  Every `V-Sekai-fire/<name>` the Sides rule names as live must not be archived
  on the org. The gate reads CLAUDE.md's Sides paragraph (only the sentence
  naming the live manifest, not the retraction paragraphs) and compares
  against the org's archived-repo set from `gh repo list`.

  Detection floor: none. An UNCHECKED (`gh` failed) counts as FAIL per rule
  3; a silent-skip on network failure reads exactly like a pass.
  """

  @org "V-Sekai-fire"

  def run(argv) do
    self_test? = "--self-test" in argv
    root =
      case Enum.find_index(argv, &(&1 == "--repo")) do
        nil -> File.cwd!()
        i -> Enum.at(argv, i + 1)
      end
    claude = Path.join(root, "CLAUDE.md")
    if not File.exists?(claude) do
      IO.puts("FAIL: #{claude} does not exist")
      1
    else
      text = File.read!(claude)
      rc = check(text)
      rc =
        if self_test? do
          IO.puts("")
          rc + self_test(text)
        else
          rc
        end
      if rc > 0, do: 1, else: 0
    end
  end

  def sides_rule(text) do
    case Regex.run(~r/\*\*Sides\.\*\*(.*?)(?=\n\*\*[A-Z])/s, text) do
      [_, body] -> body
      _ -> ""
    end
  end

  def named_live(text) do
    para = sides_rule(text) |> String.split("\n\n") |> List.first() || ""
    Regex.scan(~r/`#{Regex.escape(@org)}\/([A-Za-z0-9._\-]+)`/, para)
    |> Enum.map(fn [_, n] -> n end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  def archived_repos do
    case System.cmd("gh",
      ["repo", "list", @org, "--limit", "500", "--json", "name,isArchived"],
      stderr_to_stdout: true) do
      {out, 0} ->
        {:ok, out |> Jason.decode!() |> Enum.filter(& &1["isArchived"])
              |> Enum.map(& &1["name"]) |> MapSet.new()}
      {out, _} ->
        {:error, out |> String.split("\n", trim: true) |> List.last() || "gh failed"}
    end
  end

  def check(text) do
    live = named_live(text)
    if live == [] do
      IO.puts("  FAIL the Sides rule names no goal manifest at all")
      1
    else
      case archived_repos() do
        {:error, err} ->
          IO.puts("  FAIL UNCHECKED: could not read #{@org}'s archived set -- #{err}")
          1
        {:ok, archived} ->
          bad = Enum.filter(live, &MapSet.member?(archived, &1))
          Enum.each(bad, fn n ->
            IO.puts("  FAIL the Sides rule names #{@org}/#{n} as live, and it is archived")
          end)
          if bad != [] do
            1
          else
            IO.puts("  ok   #{length(live)} goal manifest(s) named live, none archived: #{Enum.join(live, ", ")}")
            0
          end
      end
    end
  end

  def self_test(real_text) do
    case archived_repos() do
      {:error, err} ->
        IO.puts("  FAIL UNCHECKED: #{err}")
        1
      {:ok, archived} ->
        case MapSet.to_list(archived) |> Enum.sort() do
          [] ->
            IO.puts("  SKIP: no archived repos in org — can't run self-test")
            0
          [victim | _] ->
            controls = [
              {"an archived manifest is named as live",
                String.replace(real_text, "`V-Sekai-fire/contract-manifest-taskweft`",
                               "`#{@org}/#{victim}`", global: false)},
              {"the rule names no manifest",
                mutate_sides_to_prose(real_text)}
            ]
            IO.puts("negative controls (each must FAIL):")
            bad =
              Enum.reduce(controls, 0, fn {label, mutated}, acc ->
                {out, rc} = capture_check(mutated)
                first = out |> String.split("\n") |> Enum.find("", &String.contains?(&1, "FAIL")) |> String.trim()
                if rc > 0 do
                  IO.puts("  ok   #{label}: #{first}")
                  acc
                else
                  IO.puts("  BAD  #{label}: passed, so this gate certifies the defect")
                  acc + 1
                end
              end)
            if bad > 0 do
              IO.puts("\n#{bad} control(s) did not fire. The gate is decoration until they do.")
              1
            else
              IO.puts("\nAll #{length(controls)} controls fired.")
              0
            end
        end
    end
  end

  defp mutate_sides_to_prose(real_text) do
    para = sides_rule(real_text) |> String.split("\n\n") |> List.first() || ""
    replaced = Regex.replace(~r/`#{@org}\/[a-z0-9._\-]+`/, para, "the manifest")
    String.replace(real_text, para, replaced, global: false)
  end

  defp capture_check(text) do
    # Elixir's IO capture without ExUnit: temporarily rebind :standard_io.
    parent = self()
    {:ok, pid} = StringIO.open("")
    old = Process.group_leader()
    try do
      Process.group_leader(self(), pid)
      rc = check(text)
      {:ok, {_, out}} = StringIO.close(pid)
      Process.group_leader(self(), old)
      send(parent, :ok)
      {out, rc}
    rescue
      _ ->
        Process.group_leader(self(), old)
        {"", 0}
    end
  end
end
