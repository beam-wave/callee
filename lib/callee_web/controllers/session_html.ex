defmodule CalleeWeb.SessionHTML do
  use CalleeWeb, :html
  import CalleeWeb.Layouts, only: [flash_group: 1]
  embed_templates "session_html/*"
end
