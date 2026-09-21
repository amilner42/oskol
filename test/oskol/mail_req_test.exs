defmodule Oskol.MailReqTest do
  use ExUnit.Case, async: true

  import Swoosh.Email

  test "the Postmark adapter sends through Swoosh's Req client" do
    Req.Test.stub(__MODULE__, fn conn ->
      assert conn.method == "POST"
      assert conn.request_path == "/email"
      assert Plug.Conn.get_req_header(conn, "x-postmark-server-token") == ["test-token"]

      {:ok, body, conn} = Plug.Conn.read_body(conn)

      assert %{"To" => "player@example.com", "Subject" => "Sign in to Oskol"} =
               Jason.decode!(body)

      Req.Test.json(conn, %{"MessageID" => "postmark-message-id"})
    end)

    email =
      new()
      |> from({"Oskol", "hello@oskol.io"})
      |> to("player@example.com")
      |> subject("Sign in to Oskol")
      |> text_body("code 123 456")
      |> put_private(:client_options, plug: {Req.Test, __MODULE__})

    assert {:ok, %{id: "postmark-message-id"}} =
             Swoosh.Adapters.Postmark.deliver(email, api_key: "test-token")
  end
end
