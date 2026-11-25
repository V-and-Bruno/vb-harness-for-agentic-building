# frozen_string_literal: true
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 V and Bruno LLC

# Chat's reading tools: only a project the user picked, only files git tracks, nothing that looks like a secret,
# nothing written, every result fenced (I9), and a fixed number of lookups. Figma: only links the user typed.

require_relative "../test_helper"
require_relative "../support/fake_llm_server"
require_relative "../support/ui_client"
require_relative "../support/run_fixture"
require "json"
require "tmpdir"

class ChatToolsTest < Minitest::Test
  Fake = TestSupport::FakeLlmServer
  C = TestSupport::UIClient
  T = Harness::UI::ChatTools

  def setup
    @tmp = Dir.mktmpdir("harness-chat-tools-")
    @home = File.join(@tmp, "home")
    FileUtils.mkdir_p(@home)
    @repo, @git_env = TestSupport.repo(@tmp, "README.md" => "# Shop\n", "src/price.rb" => "def price = 41\n", ".env" => "SECRET=tracked\n",
                                             "keys/server.pem" => "PRIVATE tracked\n", "package-lock.json" => "{}\n")
    File.write(File.join(@repo, "private.txt"), "untracked private\n")
    File.write(File.join(@repo, "src", "draft.rb"), "untracked draft\n")
  end

  def teardown
    @server&.stop
    @model&.stop
    FileUtils.rm_rf(@tmp)
  end

  def tools(room: 50_000)
    T.new(root: File.realpath(@repo), stack: nil, settings: Harness::Agent::Settings.defaults, git: Harness::Repo::Git.new(env: @git_env), room: room)
  end

  def inside(text) = text.lines[1..-2].join

  def test_it_offers_only_reading
    assert_equal T::NAMES.sort, tools.definitions.map { |d| d.dig("function", "name") }.sort
    t = tools
    %w[write_file edit_file delete_file run_gate run_command finish system].each do |name|
      assert_match(/error: there is no tool/, t.call(name, { "path" => "x.rb", "content" => "x", "name" => "check" }), name)
    end
    refute File.exist?(File.join(@repo, "x.rb"))
  end

  def test_it_reads_lists_and_searches_tracked_files_inside_the_fence
    t = tools
    out = t.call("read_file", JSON.generate({ "path" => "src/price.rb" }))
    assert_match(/\A<untrusted-data id="\h+">\n/, out)
    assert_includes inside(out), "def price = 41"
    assert_equal "src/price.rb", t.steps.last.target
    assert_includes t.call("search", { "text" => "price" }), "src/price.rb:1"
    assert_includes t.call("find_symbol", { "name" => "price" }), "src/price.rb"
    assert_equal %w[README.md keys/ package-lock.json src/], t.call("list_dir", { "path" => "." }).lines.map(&:chomp)[2..-2]
  end

  def test_untracked_files_and_secrets_are_not_there
    t = tools
    %w[private.txt src/draft.rb .env keys/server.pem .git/config ../home.json /etc/hosts src/../private.txt].each do |path|
      out = t.call("read_file", { "path" => path })
      assert_match(/error:/, out, path)
      refute_match(/untracked|tracked\b|SECRET|PRIVATE|localhost/, inside(out), path)
      t = tools if t.steps.size > 8
    end
    t = tools
    assert_includes t.call("search", { "text" => "untracked" }), "no match"
    assert_includes t.call("search", { "text" => "SECRET" }), "no match"
    assert_includes t.call("search", { "text" => "PRIVATE", "path" => "keys/server.pem" }), "error:"
    assert_includes t.call("search", { "text" => "untracked", "path" => "private.txt" }), "no match"
    refute_includes t.call("list_dir", { "path" => "src" }), "draft.rb"
  end

  def test_a_tracked_link_cannot_show_an_untracked_or_secret_file
    skip "no symlinks here" if Gem.win_platform?
    { "to_private" => "private.txt", "to_env" => ".env", "to_outside" => "/etc/hostname", "to_readme" => "README.md" }.each { |l, f| File.symlink(f, File.join(@repo, l)) }
    TestSupport.git!(@repo, @git_env, "add", "to_private", "to_env", "to_outside", "to_readme")
    t = tools
    %w[to_private to_env to_outside].each { |l| assert_match(/error:/, t.call("read_file", { "path" => l }), l) }
    assert_includes t.call("read_file", { "path" => "to_readme" }), "# Shop"
    assert_includes t.call("search", { "text" => "untracked" }), "no match"
  end

  def test_lookups_and_their_size_are_limited_and_bad_calls_are_answered
    t = tools
    (T::MAX_CALLS + 3).times { t.call("list_dir", { "path" => "." }) }
    refute t.more?
    assert_match(/no more reading/, t.call("read_file", { "path" => "README.md" }))
    small = tools(room: 120)
    assert_match(/does not fit/, small.call("list_dir", { "path" => "." })) if tools.call("list_dir", { "path" => "." }).size > 120
    assert_match(/one JSON object/, tools.call("read_file", "{not json"))
    assert_match(/one JSON object/, tools.call("read_file", "[1]"))
    assert_match(/error:/, tools.call("read_file", nil))
  end

  # --- in the app ---

  def stream(*deltas, finish: "stop")
    lines = deltas.map { |d| "data: #{JSON.generate({ 'choices' => [{ 'delta' => d }] })}\n\n" }
    [200, "#{lines.join}data: #{JSON.generate({ 'choices' => [{ 'delta' => {}, 'finish_reason' => finish }] })}\n\ndata: [DONE]\n\n"]
  end

  TOOL_CALL = { "id" => "1", "type" => "function", "function" => { "name" => "record_value", "arguments" => '{"value":42}' } }.freeze

  def start(native: true, env: ENV.to_h, &script)
    seen = -1
    @model = Fake.new do |body, _n|
      if body["stream"] then script.call(body, seen += 1)
      elsif body["tools"] && native then Fake.ok(nil, finish: "tool_calls", tool_calls: [TOOL_CALL])
      else Fake.ok("OK")
      end
    end
    File.write(File.join(@home, "config.json"), JSON.generate({ "profiles" => { "default" => { "baseUrl" => @model.base_url, "model" => "test-model" } },
                                                                "gateEnvAllow" => %w[GIT_CONFIG_GLOBAL GIT_CONFIG_NOSYSTEM],
                                                                "projects" => [{ "name" => "shop", "path" => @repo }] }))
    app = Harness::UI::App.new(config_path: File.join(@home, "config.json"), token: "k" * 64, env: env.merge(@git_env),
                               pipeline_for: ->(*) { raise "not used" })
    @server = Harness::UI::Server.new(app: app, port: 0, token: "k" * 64)
    @server.start
  end

  def post(path, body = {}) = C.post(@server.port, "k" * 64, path, body)
  def get(path) = C.request(@server.port, "GET", path)

  def test_a_reply_looks_things_up_and_answers
    piece = ->(h) { { "tool_calls" => [{ "index" => 0 }.merge(h)] } }
    start do |body, n|
      if n.zero?
        stream({ "content" => "Let me look." }, piece.call({ "id" => "c9", "function" => { "name" => "read_file", "arguments" => "" } }),
               piece.call({ "function" => { "arguments" => '{"path":"src/' } }), piece.call({ "function" => { "arguments" => 'price.rb"}' } }), finish: "tool_calls")
      else stream({ "content" => "The price is 41." })
      end
    end
    assert_equal({ "images" => false, "tools" => true }, get("/api/abilities?profile=default&model=test-model").json)
    chat = post("/api/chats").json["id"]
    out = post("/api/chats/#{chat}/send", { "text" => "What is the price?", "mode" => "chat", "reads" => "shop" }).json
    events = get("/api/streams/#{out['stream']}").body
    assert_includes events, "event: read\ndata: {\"tool\":\"read_file\",\"target\":\"src/price.rb\",\"ok\":true}"
    asked = @model.chat_bodies.select { |b| b["stream"] }
    assert_equal 2, asked.size
    assert_equal T::NAMES.sort, asked.first["tools"].map { |d| d.dig("function", "name") }.sort
    assert_match(/picked the project shop/, asked.first["messages"].first["content"])
    call, result = asked.last["messages"].last(2)
    assert_equal ["c9", "read_file", '{"path":"src/price.rb"}'], [call["tool_calls"][0]["id"], *call["tool_calls"][0]["function"].values_at("name", "arguments")]
    assert_equal %w[tool c9], result.values_at("role", "tool_call_id")
    assert_match(/<untrusted-data id="\h+">.*def price = 41.*<\/untrusted-data/m, result["content"])
    saved = get("/api/chats/#{chat}").json["messages"]
    assert_equal ["Let me look.\n\nThe price is 41.", [{ "tool" => "read_file", "target" => "src/price.rb", "ok" => true }]], saved.last.values_at("content", "read")
    refute_includes JSON.generate(saved), "def price", "what was read is not kept in the chat"
  end

  def test_a_model_that_never_stops_looking_things_up_is_stopped
    start do |body, _n|
      body["tool_choice"] == "none" ? stream({ "content" => "Enough." }) :
        stream({ "tool_calls" => [{ "index" => 0, "id" => "x", "function" => { "name" => "list_dir", "arguments" => '{"path":"."}' } }] }, finish: "tool_calls")
    end
    chat = post("/api/chats").json["id"]
    out = post("/api/chats/#{chat}/send", { "text" => "Look", "mode" => "chat", "reads" => "shop" }).json
    get("/api/streams/#{out['stream']}")
    assert_equal T::MAX_CALLS + 1, @model.chat_bodies.count { |b| b["stream"] }
    assert_equal "Enough.", get("/api/chats/#{chat}").json["messages"].last["content"].strip
  end

  def test_nothing_is_read_unless_a_project_is_picked_and_the_model_calls_tools
    start(native: false) { |_b, _n| stream({ "content" => "Hi" }) }
    chat = post("/api/chats").json["id"]
    r = post("/api/chats/#{chat}/send", { "text" => "Look", "mode" => "chat", "reads" => "shop" })
    assert_equal [400, "this model cannot look things up: it does not call tools"], [r.status, r.json["error"]]
    assert_equal 404, post("/api/chats/#{chat}/send", { "text" => "Look", "mode" => "chat", "reads" => "../secret" }).status, "a project by name, never a path"
    out = post("/api/chats/#{chat}/send", { "text" => "Hello", "mode" => "chat" }).json
    get("/api/streams/#{out['stream']}")
    refute @model.chat_bodies.any? { |b| b["stream"] && b.key?("tools") }
  end

  def test_a_figma_link_without_a_token_is_explained_and_the_model_is_told
    start(env: ENV.to_h.reject { |k, _| k == "FIGMA_TOKEN" }) { |_b, _n| stream({ "content" => "I cannot see it." }) }
    chat = post("/api/chats").json["id"]
    out = post("/api/chats/#{chat}/send", { "text" => "See https://www.figma.com/design/abc/X?node-id=1-2", "mode" => "chat" }).json
    events = get("/api/streams/#{out['stream']}").body
    assert_match(/event: notice\ndata: .*FIGMA_TOKEN is not set/, events)
    assert_match(/could not be read: .*FIGMA_TOKEN/, @model.chat_bodies.reverse.find { |b| b["stream"] }["messages"].last["content"])
  end
end
