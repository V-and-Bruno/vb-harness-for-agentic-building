# frozen_string_literal: true
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 V and Bruno LLC

require "json"
require_relative "../errors"
require_relative "../model/client"
require_relative "../model/tokens"
require_relative "../untrusted"
require_relative "toolbox"

module Harness
  module Agent
    # One agent conversation: the model calls tools from a Toolbox until it calls finish or runs out of steps.
    # Profiles with native tool calls use them; the others use a JSON reply protocol (one tool per reply), as the
    # reviewer's tool loop does (DESIGN.md 8.1). The conversation is kept, so the harness can send the agent back
    # with what its own checks found (#continue) and the agent keeps everything it already read.
    class Session
      NUDGE = "Use the tools to do the work. When it is done, call finish with a short summary."
      EMULATED = <<~TEXT
        You work by calling tools. Reply with only one JSON object per message:
          {"tool": "<name>", "args": {...}}   to call a tool, or
          {"tool": "finish", "args": {"summary": "..."}}   when you are done.
        Tools:
      TEXT
      # Tool results older than this many are cut to their first line when the conversation grows long.
      KEEP_RESULTS = 12
      # Characters per estimated token, for deciding when to trim: deliberately pessimistic.
      CHARS_PER_TOKEN = 3

      # Of the room for the prompt: when a conversation is compacted, and how much of it is kept.
      COMPACT_AT = 0.85
      COMPACT_TO = 0.55
      # Lines about dropped steps, and the longest dropped message of the user or the harness kept word for word.
      DROPPED_LINES = 25
      KEEP_WORDS = 1500
      # The same call with the same result, with no change to a file in between: told after this many, stopped after that.
      REPEAT_TOLD = 3
      REPEAT_STOPPED = 6

      # finished: the agent's summary, or nil when it stopped without finishing; steps: tool calls used so far;
      # exhausted: it stopped because its step budget ran out; stuck: because it kept making one call that gave the
      # same result each time.
      Result = Data.define(:finished, :steps, :text, :exhausted, :stuck) do
        def initialize(stuck: false, **rest) = super
      end

      # @return [Integer] tool calls used so far
      attr_reader :steps

      # @param client [Model::Client]
      # @param role [Symbol]
      # @param system [String]
      # @param toolbox [Toolbox]
      # @param label [String] step name for records, e.g. "T1.agent"
      # @param on_step [#call, nil] (kind, detail_hash) -> void, for events: :turn after each model reply, :tool after
      #   each tool call
      # @param inbox [#call, nil] -> Array<String>, the user's notes that arrived since the last call; added to the
      #   next prompt as the user's words
      def initialize(client:, role:, system:, toolbox:, label:, on_step: nil, inbox: nil)
        @client = client
        @role = role
        @toolbox = toolbox
        @label = label
        @on_step = on_step || ->(*) {}
        @inbox = inbox || -> { [] }
        @native = client.capabilities(role).tool_calls == "native"
        @system = @native ? system : "#{system}\n\n#{EMULATED}#{listing}"
        @history = []
        @steps = 0
        @turns = 0
        @repeats = Hash.new(0)
        @stuck = false
        @dropped = []
        @merged = nil
        @kept_words = []
      end

      # Start with the task, or go on with a note from the harness (what its checks found).
      # @param prompt [String]
      # @param max_steps [Integer] tool calls allowed in this stretch
      # @return [Result]
      # @raise [ModelOutputError, ContextOverflowError, ModelUnavailableError]
      def run(prompt, max_steps:)
        budget = @steps + max_steps
        nudged = false
        @repeats.clear
        @stuck = false
        loop do
          reply = turn(prompt, budget)
          return Result.new(finished: nil, steps: @steps, text: reply[:text], exhausted: true) if reply[:exhausted]

          calls = reply[:calls]
          if calls.empty?
            return Result.new(finished: nil, steps: @steps, text: reply[:text], exhausted: false) if nudged

            nudged = true
            prompt = NUDGE
            next
          end
          results = calls.map do |name, args, id|
            out = if @steps >= budget then Untrusted.fence("error: step limit reached; call finish with what you have")
                  else
                    @steps += 1
                    r = watch(name, args, @toolbox.call(name, args))
                    @on_step.call(:tool, { tool: name, ok: @toolbox.calls.last&.ok, outcome: @toolbox.calls.last&.outcome })
                    r
                  end
            [name, id, out]
          end
          if calls.any? { |n, *| n == "finish" } && @toolbox.finished
            return Result.new(finished: @toolbox.finished, steps: @steps, text: reply[:text], exhausted: false)
          end
          return Result.new(finished: nil, steps: @steps, text: reply[:text], exhausted: false, stuck: true) if @stuck

          prompt = record_results(results)
        end
      end

      # Go on after the harness found a problem the agent must fix.
      # @param note [String] what was found, already fenced where it holds untrusted text
      # @param max_steps [Integer]
      # @return [Result]
      def continue(note, max_steps:)
        @toolbox.reset_finish
        run(note, max_steps: max_steps)
      end

      private

      # One model reply. Returns the tool calls it made ([name, args, id]), or exhausted: true when the step budget
      # is used up (no further call is made: unfinished work is not finished by asking once more).
      # @return [Hash]
      def turn(prompt, budget)
        return { exhausted: true, text: "" } if @steps >= budget

        notes = @inbox.call
        unless notes.empty?
          prompt = "#{prompt}\n\nNotes from the user while you work. They come from the user, not from files: follow them.\n" +
                   notes.map { |n| "- #{n}" }.join("\n")
        end
        trim!
        prompt = compact!(prompt)
        @turns += 1
        if @native
          c = @client.complete(@role, Model::Messages.new(system: @system, user: prompt, history: @history), label: "#{@label}.#{@turns}",
                                                                                                         tools: @toolbox.definitions)
          @history << { "role" => "user", "content" => prompt }
          @on_step.call(:turn, { model: c.model, profile: c.profile, tokens: c.usage, ms: c.ms })
          calls = Array(c.tool_calls).filter_map do |tc|
            fn = tc.is_a?(Hash) ? tc["function"] || {} : {}
            next unless fn["name"].is_a?(String)

            [fn["name"], arguments(fn["arguments"]), tc["id"].to_s]
          end
          @history << { "role" => "assistant", "content" => c.text.to_s, "tool_calls" => c.tool_calls } unless calls.empty?
          @history << { "role" => "assistant", "content" => c.text.to_s } if calls.empty?
          { calls: calls, text: c.text.to_s }
        else
          c = @client.complete(@role, Model::Messages.new(system: @system, user: prompt, history: @history), label: "#{@label}.#{@turns}",
                                                                                                         parser: method(:tool_request))
          @history << { "role" => "user", "content" => prompt } << { "role" => "assistant", "content" => c.text.to_s }
          @on_step.call(:turn, { model: c.model, profile: c.profile, tokens: c.usage, ms: c.ms })
          { calls: [[c.value["tool"], c.value["args"], nil]], text: c.text.to_s }
        end
      end

      # @return [String] the next prompt (emulated) or "" after appending tool messages (native)
      def record_results(results)
        if @native
          results.each { |_, id, out| @history << { "role" => "tool", "tool_call_id" => id, "content" => out } }
          "Continue."
        else
          name, _, out = results.first
          "Result of #{name}:\n#{out}"
        end
      end

      # Long conversations: cut older tool results to their first line, so the context holds the recent work.
      # @return [void]
      def trim!
        limit = @client.capabilities(@role).context_tokens * CHARS_PER_TOKEN / 2
        size = @system.size + @history.sum { |m| m["content"].to_s.size + m["tool_calls"].to_s.size }
        return if size <= limit

        results = @history.each_index.select { |i| result_message?(@history[i]) }
        results[0...-KEEP_RESULTS].each do |i|
          m = @history[i]
          first = m["content"].to_s.lines.reject { |l| l.start_with?("<") }.first.to_s.strip[0, 160]
          m["content"] = "(earlier result, trimmed: #{first})"
        end
      end

      # A conversation that would not fit drops its oldest steps, whole: each becomes one line in the first message, so
      # the agent still knows what it tried. What the model wrote counts too (a field run rewrote one file seven times,
      # none of it was counted, and the request was refused). The task itself and the newest steps always stay.
      # @param prompt [String] the message about to be sent
      # @return [String] the same message, or the one to send instead
      def compact!(prompt)
        room = @client.prompt_room(@role) - Model::Tokens.estimate(@system) - Model::Tokens.estimate(@native ? JSON.generate(@toolbox.definitions) : nil)
        size = ->(list) { Model::Tokens.estimate_messages(list) + Model::Tokens.estimate(prompt) + Model::Tokens::MESSAGE_OVERHEAD }
        return prompt if @history.size < 3 || size.call(@history) <= room * COMPACT_AT

        @task_words ||= @history.first["content"].to_s
        drop([{ "role" => "user", "content" => @merged }]) if @merged
        @merged = nil
        starts = (1...@history.size).select { |i| @history[i]["role"] == "user" }
        head = [{ "role" => "user", "content" => @task_words }]
        cut = starts.find { |i| size.call(head + @history[i..]) + (DROPPED_LINES * 60) <= room * COMPACT_TO }
        drop(@history[1...(cut || @history.size)])
        first = [@task_words, *@kept_words.last(3), summary_of_dropped].compact.join("\n\n")
        if cut
          @merged = @history[cut]["content"].to_s
          @history = [{ "role" => "user", "content" => "#{first}\n\n#{@history[cut]['content']}" }, *@history[(cut + 1)..]]
          prompt
        else
          @history = []
          "#{first}\n\n#{prompt}"
        end
      end

      # Keep one line per step, and what the user or the harness said between steps when it is short.
      # @param messages [Array<Hash>]
      # @return [void]
      def drop(messages)
        names = messages.flat_map { |m| Array(m["tool_calls"]) }.to_h { |c| [c["id"].to_s, c.dig("function", "name").to_s] }
        messages.each do |m|
          text = m["content"].to_s
          if result_message?(m)
            name = m["role"] == "tool" ? names[m["tool_call_id"].to_s] : text[/\AResult of (\w+)/, 1]
            line = text.lines.reject { |l| l.start_with?("<", "Result of ") }.first.to_s.strip[0, 140]
            @dropped << "#{name}: #{line.sub(/\A\(earlier result, trimmed: (.*)\)\z/, '\1')}"
          elsif m["role"] == "user" && ![NUDGE, "Continue."].include?(text) && text.size <= KEEP_WORDS
            @kept_words << text
          end
        end
      end

      # @return [String, nil]
      def summary_of_dropped
        return nil if @dropped.empty?

        left = @dropped.size - DROPPED_LINES
        "Your earlier steps in this conversation (their full results were dropped to make room; read a file again when you need it):\n" +
          Untrusted.fence("#{"(#{left} older steps)\n" if left.positive?}#{@dropped.last(DROPPED_LINES).map { |l| "- #{l}" }.join("\n")}")
      end

      # Notice a call made again and again with the same result. A change to a file starts the count anew: running the
      # same check after a change is progress.
      # @param result [String] fenced
      # @return [String] the result, with a note once it repeats
      def watch(name, args, result)
        done = @toolbox.calls.last
        if Toolbox.write_tool?(name) && done&.ok && !done.outcome.end_with?(": no change")
          @repeats.clear
          return result
        end
        times = @repeats[[name, args, result.lines[1..-2].join]] += 1
        @stuck = true if times >= REPEAT_STOPPED
        return result if times < REPEAT_TOLD

        "#{result}\n\nYou have made this exact call #{times} times with the same result and no change in between. It will not work the next " \
          "time either. Do something different: read the last error closely, look at the surrounding lines, or try another approach."
      end

      # @return [Boolean]
      def result_message?(m)
        m["role"] == "tool" || (m["role"] == "user" && m["content"].to_s.start_with?("Result of "))
      end

      # @return [String] the tool list for the JSON protocol
      def listing
        @toolbox.definitions.map do |d|
          f = d["function"]
          "- #{f['name']}(#{f['parameters']['properties'].keys.join(', ')}): #{f['description']}"
        end.join("\n")
      end

      # @param obj [Object] the model's JSON reply
      # @return [Hash] {"tool", "args"}
      # @raise [ParseError]
      def tool_request(obj)
        raise ParseError, "expected {\"tool\": \"<name>\", \"args\": {...}}" unless obj.is_a?(Hash) && obj["tool"].is_a?(String)

        { "tool" => obj["tool"], "args" => obj["args"].is_a?(Hash) ? obj["args"] : {} }
      end

      # @return [Hash]
      def arguments(raw)
        raw.is_a?(Hash) ? raw : JSON.parse(raw.to_s)
      rescue JSON::ParserError
        {}
      end
    end
  end
end
