# frozen_string_literal: true
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 V and Bruno LLC

# An agent's conversation: it is kept inside the context whatever the model writes, and a model that makes the same
# call over and over is told, then stopped (a field run did both for an hour and was blocked on an overflow).

require_relative "../test_helper"
require_relative "../support/fake_llm_server"
require "json"
require "tmpdir"

class AgentSessionTest < Minitest::Test
  Fake = TestSupport::FakeLlmServer
  S = Harness::Agent::Session

  def setup
    @tmp = Dir.mktmpdir("harness-session-")
    @root = File.join(@tmp, "wt")
    FileUtils.mkdir_p(@root)
    File.write(File.join(@root, "a.txt"), "one\ntwo\n")
    File.write(File.join(@root, "big.txt"), (1..400).map { |i| "line #{i} of the big file\n" }.join)
  end

  def teardown
    @server&.stop
    FileUtils.rm_rf(@tmp)
  end

  def call(name, args, id = "c#{@n = @n.to_i + 1}") = { "id" => id, "type" => "function", "function" => { "name" => name, "arguments" => JSON.generate(args) } }
  def tool(name, args) = Fake.ok("", tool_calls: [call(name, args)])
  def finish = tool("finish", { "summary" => "Done." })

  def session(context: 60_000, native: true, inbox: nil, &script)
    n = -1
    @server = Fake.new { |_body, _| script.call(n += 1) }
    client = TestSupport.client(@server.base_url, @tmp, caps: { context_tokens: context, tool_calls: native ? "native" : "none" }, profile: { maxOutputTokens: 1000 })
    @toolbox = Harness::Agent::Toolbox.new(root: @root, protected: [], stack: nil, settings: Harness::Agent::Settings.defaults, writable: true)
    S.new(client: client, role: :implementer, system: "You work.", toolbox: @toolbox, label: "t", inbox: inbox)
  end

  def bodies = @server.chat_bodies
  def estimate(body) = Harness::Model::Tokens.estimate_messages(body["messages"]) + Harness::Model::Tokens.estimate(body["tools"] && JSON.generate(body["tools"]))

  # --- repeating ---

  def test_a_call_repeated_with_the_same_result_is_pointed_out_then_stopped
    r = session { |_| tool("read_file", { "path" => "a.txt" }) }.run("Do it.", max_steps: 40)
    assert r.stuck
    assert_nil r.finished
    assert_equal S::REPEAT_STOPPED, r.steps
    told = bodies.map { |b| b["messages"].select { |m| m["role"] == "tool" }.last&.fetch("content") }.compact
    refute_includes told[S::REPEAT_TOLD - 2], "exact call"
    assert_includes told[S::REPEAT_TOLD - 1], "this exact call #{S::REPEAT_TOLD} times"
    assert_match(/<\/untrusted-data id="\h+">\n\nYou have made/, told[S::REPEAT_TOLD - 1], "the note is the harness's, outside the fence")
  end

  def test_a_rewrite_that_changes_nothing_counts_as_repeating
    File.write(File.join(@root, "same.txt"), "x\n")
    s = session { |i| i.zero? ? tool("write_file", { "path" => "new.txt", "content" => "x\n" }) : tool("write_file", { "path" => "new.txt", "content" => "x\n" }) }
    r = s.run("Do it.", max_steps: 40)
    assert r.stuck
    assert_equal 1 + S::REPEAT_STOPPED, r.steps, "the write that changed the file does not count"
  end

  def test_the_same_check_after_each_change_is_not_repeating
    s = session do |i|
      if i >= 20 then finish
      elsif i.even? then tool("write_file", { "path" => "n.txt", "content" => "#{i}\n" })
      else tool("read_file", { "path" => "a.txt" })
      end
    end
    r = s.run("Do it.", max_steps: 40)
    assert_equal ["Done.", false], [r.finished, r.stuck]
  end

  def test_a_new_stretch_starts_the_count_anew
    s = session { |i| i == S::REPEAT_STOPPED - 1 || i > 10 ? finish : tool("read_file", { "path" => "a.txt" }) }
    assert_equal "Done.", s.run("Do it.", max_steps: 40).finished
    r = s.continue("Go on.", max_steps: 40)
    refute r.stuck if r.finished
    assert_operator r.steps, :>, S::REPEAT_STOPPED
  end

  # --- staying inside the context ---

  def long_run(context:, native: true, inbox: nil, steps: 24)
    ask = ->(name, args) { native ? tool(name, args) : Fake.ok(JSON.generate({ "tool" => name, "args" => args })) }
    s = session(context: context, native: native, inbox: inbox) do |i|
      if i >= steps then ask.call("finish", { "summary" => "Done." })
      elsif i % 3 == 2 then ask.call("read_file", { "path" => "big.txt", "start_line" => i, "end_line" => i + 60 })
      else ask.call("write_file", { "path" => "f#{i}.txt", "content" => "text #{i} " * 300 })
      end
    end
    s.run("THE TASK: write the files.", max_steps: 60)
  end

  [true, false].each do |native|
    define_method("test_a_long_conversation_stays_inside_the_context_#{native ? 'with_tool_calls' : 'by_json'}") do
      skip "the file cap" if Harness::Agent::Settings.defaults.max_files_per_task < 1
      r = long_run(context: 14_000, native: native)
      assert_equal "Done.", r.finished, "nothing was refused for its size"
      bodies.each { |b| assert_operator estimate(b) + b["max_tokens"], :<=, 14_000 }
      bodies.each { |b| assert b["messages"].find { |m| m["role"] == "user" }["content"].start_with?("THE TASK: write the files."), "the task always stays" }
      last = bodies.last["messages"]
      assert_includes last.map { |m| m["content"].to_s }.join, "Your earlier steps in this conversation"
      assert_match(/<untrusted-data id="\h+">\n(?:\(\d+ older steps\)\n)?- \w+: /, last[1]["content"], "what was dropped is fenced, one line each")
      roles = last.map { |m| m["role"] }
      refute roles.each_cons(2).any? { |a, b| a == b && a == "user" }, "two user messages never follow each other: #{roles.inspect}"
      if native
        answered = last.select { |m| m["role"] == "tool" }.map { |m| m["tool_call_id"] }
        assert_equal answered, last.flat_map { |m| Array(m["tool_calls"]) }.map { |c| c["id"] }, "every call kept has its result, and no result is orphaned"
      end
    end
  end

  def test_what_the_user_said_is_kept_when_the_steps_around_it_are_dropped
    said = false
    inbox = lambda do
      next [] if said || bodies.size < 3

      said = true
      ["Use the blue logo."]
    end
    long_run(context: 14_000, inbox: inbox)
    assert_includes bodies.last["messages"].map { |m| m["content"].to_s }.join, "Use the blue logo."
  end

  def test_a_short_conversation_is_left_alone
    long_run(context: 200_000, steps: 6)
    assert_equal 6, bodies.last["messages"].count { |m| m["role"] == "tool" }
    refute_includes bodies.last["messages"].map { |m| m["content"].to_s }.join, "Your earlier steps"
  end
end
