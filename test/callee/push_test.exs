defmodule Callee.PushTest do
  use ExUnit.Case, async: true

  # Decrypt per RFC 8291 as a user agent would, to check our encryption.
  test "aes128gcm payload round-trips" do
    {ua_pub, ua_priv} = :crypto.generate_key(:ecdh, :prime256v1)
    auth = :crypto.strong_rand_bytes(16)
    body = Callee.Push.encrypt(~s({"hello":"world"}), ua_pub, auth)

    <<salt::binary-16, 4096::32, 65::8, as_pub::binary-65, ct::binary>> = body
    ecdh = :crypto.compute_key(:ecdh, as_pub, ua_priv, :prime256v1)
    h = &:crypto.mac(:hmac, :sha256, &1, &2)
    ikm = h.(h.(auth, ecdh), "WebPush: info" <> <<0>> <> ua_pub <> as_pub <> <<1>>)
    prk = h.(salt, ikm)
    <<cek::binary-16, _::binary>> = h.(prk, "Content-Encoding: aes128gcm" <> <<0, 1>>)
    <<nonce::binary-12, _::binary>> = h.(prk, "Content-Encoding: nonce" <> <<0, 1>>)

    {data, tag} =
      {binary_part(ct, 0, byte_size(ct) - 16), binary_part(ct, byte_size(ct) - 16, 16)}

    assert :crypto.crypto_one_time_aead(:aes_128_gcm, cek, nonce, data, "", tag, false) ==
             ~s({"hello":"world"}) <> <<2>>
  end
end
