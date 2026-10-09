defmodule Callee.ClientUploadsTest do
  use Callee.DataCase, async: false
  alias Callee.{Accounts, Calls, Repo}
  alias Callee.Calls.{Call, Recording}
  alias Callee.Recording.ClientUploads

  setup do
    dir = Path.join(System.tmp_dir!(), "callee-cu-#{System.unique_integer([:positive])}")
    Application.put_env(:callee, :recording_dir, dir)
    on_exit(fn -> File.rm_rf(dir) end)
    exp = DateTime.add(DateTime.utc_now(), 86_400) |> DateTime.truncate(:second)

    {:ok, t} =
      Accounts.create_tenant(%{
        name: "Org",
        username: "cuorg",
        password: "password1",
        expires_at: exp
      })

    {:ok, c, _} =
      Accounts.add_contact(t, %{"name" => "X", "mobile" => "7111111111", "password" => "pw1234"})

    call =
      Repo.insert!(%Call{
        tenant_id: t.id,
        client_id: c.client_id,
        caller_type: "tenant",
        status: "active"
      })

    {:ok, _} =
      Calls.create_recording(call, %{
        s3_key: "pending",
        content_type: "x",
        status: "recording",
        mode: "client"
      })

    %{call: call}
  end

  defp part(bytes) do
    p = Path.join(System.tmp_dir!(), "part-#{System.unique_integer([:positive])}")
    File.write!(p, bytes)
    %Plug.Upload{path: p, filename: "p", content_type: "audio/webm"}
  end

  test "parts append in order, duplicates are idempotent, gaps are rejected", %{call: call} do
    assert {:ok, 1} = ClientUploads.append(call, 0, part("AAA"), "audio/webm", false, 60)
    assert {:ok, 2} = ClientUploads.append(call, 1, part("BBB"), "audio/webm", false, 120)
    # retry of an already stored part: acknowledged, not written twice
    assert {:ok, 2} = ClientUploads.append(call, 1, part("BBB"), "audio/webm", false, 120)
    # skipping ahead is refused with the expected seq
    assert {:error, {:expected, 2}} =
             ClientUploads.append(call, 5, part("ZZZ"), "audio/webm", false, nil)

    assert File.read!(ClientUploads.path(call.id)) == "AAABBB"
    rec = Repo.get_by!(Recording, call_id: call.id)
    assert rec.parts_received == 2 and rec.bytes_received == 6 and rec.status == "uploading"
    assert rec.content_type == "audio/webm"
  end
end
