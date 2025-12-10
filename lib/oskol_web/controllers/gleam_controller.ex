defmodule OskolWeb.GleamController do
  use OskolWeb, :controller

  def hello(conn, _params) do
    # Call Gleam module - note the :atom syntax for compiled Gleam modules
    message = :hello.greet()

    json(conn, %{message: message, source: "gleam"})
  end

  def hello_name(conn, %{"name" => name}) do
    # Call Gleam function with parameter
    message = :hello.greet_with_name(name)

    json(conn, %{message: message, source: "gleam", name: name})
  end

  def hello_name(conn, _params) do
    # Fallback if no name provided
    json(conn, %{error: "name parameter required"})
  end
end
