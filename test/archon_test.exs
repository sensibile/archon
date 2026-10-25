defmodule ArchonTest do
  use ExUnit.Case
  doctest Archon

  test "greets the world" do
    assert Archon.hello() == :world
  end
end
